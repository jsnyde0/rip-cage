#!/usr/bin/env bash
# test-claude-concurrency.sh — NEEDS_CONTAINER e2e test
#
# Verifies per-session Claude config isolation (rip-cage-p1p):
#   1. Concurrent-race proof   — two claude -p runs with distinct CLAUDE_CONFIG_DIR
#   2. Isolation proof         — distinct .claude.json files; shared .credentials.json symlink
#   3a. MCP-carryover proof    — real set-equality: seeded session MCP set == base snapshot set (non-empty)
#   3b. MCP-sentinel supplement — deterministic: an injected sentinel survives seed-by-copy
#   3c. R4 regression guard    — snapshot-seeded despite broken live ~/.claude.json mount
#   4. No-leftover guard       — no session-written files leaked into shared ~/.claude root
#   5. Single-agent no-regression — one-agent claude -p succeeds; auth-bootstrap intact
#   6. Git-author proof        — herdr session (HERDR_SESSION) sets GIT_AUTHOR_NAME=<handle>
#
# NEGATIVE CONTROL: manufactures the sticky-miss trigger state directly (not
# a real race — concurrency is not load-bearing for it) and asserts the
# harness's own sticky-miss detector (_sticky_miss_detected, shared with
# Step 1) actually recognizes the real claude binary's output — a detector
# validation, not a race reproduction.
#
# Pre-conditions: docker available (image build only); rip-cage:latest built;
# a running msb cage exists (name passed as RC_TEST_CONTAINER or auto-detected
# via `rc ls --output json`).
#
# Wired into tests/run-host.sh as NEEDS_CONTAINER per ADR-013.
#
# Hard rules (repo lessons):
#   - FAILURES counter + exit $FAILURES at end; no "fail via prose + exit 0".
#   - Every absence assertion is gated on a positive sentinel (both runs exited 0).
#   - set -e is fine here; run-host.sh driver loop does not propagate set -e.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Guard: skip if docker unavailable
# (docker still builds the rip-cage image; msb runs it — this guard is about
# the image build tool, not cage resolution/exec, which are msb-native below)
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: skip if no rip-cage image built
# ---------------------------------------------------------------------------
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not built — run ./rc build first"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve test container: prefer explicit RC_TEST_CONTAINER; else find running
# (msb-native: cages are invisible to docker ps/exec)
# ---------------------------------------------------------------------------
CONTAINER="${RC_TEST_CONTAINER:-}"
if [[ -z "$CONTAINER" ]]; then
  CONTAINER=$("$RC" ls --output json | jq -r '.[] | select(.status=="running") | .name' | head -1)
fi
if [[ -z "$CONTAINER" ]]; then
  echo "SKIP: no running rip-cage container found; pass RC_TEST_CONTAINER=<name> or start one with rc up"
  exit 0
fi
echo "=== test-claude-concurrency.sh ==="
echo "Container: $CONTAINER"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a command inside the container as agent user
cexec() { "$RC" exec "$CONTAINER" -- "$@"; }

# Snapshot the list of files directly under ~/.claude (not recursing into subdirs
# we explicitly symlink like projects/sessions — those aren't session-written).
# Returns sorted list of filenames.
_shared_root_files() {
  cexec find /home/agent/.claude -maxdepth 1 -not -name '.' 2>/dev/null | sort || true
}

# Shared sticky-miss clobber predicate (rip-cage-7atw.22 acceptance criterion
# 4, round-2 review Ruling 2): the ONE place that defines what counts as
# evidence of the sticky-miss "configuration file not found" bug. Step 1's
# detector (below) and the NEGATIVE CONTROL both call this SAME function —
# they must never each carry their own copy of the pattern, or they drift
# apart (round 2's exact finding: the control's pattern had grown broader
# and case-insensitive relative to the detector it was meant to validate,
# so it could go green on text the real detector would never see). Case-
# sensitive, single literal — matches the exact phrase documented as the
# trigger text (examples/claude/claude-session-wrapper.sh:111) and nothing
# broader.
_sticky_miss_detected() {
  grep -q 'configuration file not found' "$1"
}

# ---------------------------------------------------------------------------
# Posture detection: possession vs non-possession (rip-cage-7atw.10)
#
# The concurrency test predates the non-possession credential machinery and
# used to assert possession UNCONDITIONALLY (credential symlink, oauthAccount
# carryover). The session-wrapper is already posture-aware (creates the
# .credentials.json symlink only if the source exists,
# examples/claude/claude-session-wrapper.sh:77-89); this test now mirrors
# that: gate possession-only assertions on the ambient cage's posture instead
# of assuming possession.
#
# Detection: prefer the host-side rc.auth.credential-mounts.claude label
# (cheap, not forgeable by an in-cage agent, same signal
# test-claude-json-seed-synthesis.sh and test-cc-managed-settings-probe.sh
# use); fall back to an in-cage credentials-file presence check when the
# label is absent (e.g. a container not created via `rc up`).
# ---------------------------------------------------------------------------
CRED_MOUNTS_LABEL=$(msb inspect "$CONTAINER" --format json 2>/dev/null | jq -r '.config.labels["rc.auth.credential-mounts.claude"] // empty')
if [[ "$CRED_MOUNTS_LABEL" == "none" ]]; then
  POSSESSION=false
elif [[ -n "$CRED_MOUNTS_LABEL" ]]; then
  POSSESSION=true
elif cexec test -f /home/agent/.claude/.credentials.json; then
  POSSESSION=true
else
  POSSESSION=false
fi
if [[ "$POSSESSION" == "true" ]]; then
  echo "Credential posture: possession (rc.auth.credential-mounts.claude=${CRED_MOUNTS_LABEL:-<absent, .credentials.json found in-cage>})"
else
  echo "Credential posture: non-possession (rc.auth.credential-mounts.claude=${CRED_MOUNTS_LABEL:-<absent, no .credentials.json in-cage>})"
fi

# ---------------------------------------------------------------------------
# Step 0: Ensure the claude wrapper is in place
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 0: claude wrapper on PATH ==="
WRAPPER_PATH=$(cexec which claude)
if [[ "$WRAPPER_PATH" == "/usr/local/bin/claude" ]]; then
  pass "claude wrapper is at /usr/local/bin/claude (precedes /usr/bin/claude)"
else
  fail "claude wrapper not at /usr/local/bin/claude" "which claude = $WRAPPER_PATH"
fi

# ---------------------------------------------------------------------------
# Pre-step: clean up any stale test session dirs from prior runs
# ---------------------------------------------------------------------------
cexec rm -rf /home/agent/.claude-sessions/conctest-a
cexec rm -rf /home/agent/.claude-sessions/conctest-b
cexec rm -rf /home/agent/.claude-sessions/conctest-shared
cexec rm -rf /home/agent/.claude-sessions/conctest-singleagent
cexec rm -rf /home/agent/.claude-sessions/conctest-mcp-setequal
cexec rm -rf /home/agent/.claude-sessions/conctest-mcp-sentinel
cexec rm -rf /home/agent/.claude-sessions/conctest-r4-guard

# Snapshot the shared root BEFORE any claude runs (needed for step 4)
BEFORE_FILES=$(_shared_root_files)

# ---------------------------------------------------------------------------
# Step 1: Concurrent-race proof
# Two backgrounded claude -p calls with distinct CLAUDE_CONFIG_DIR
# Both must exit 0 and both stdout must contain READY
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: Concurrent-race proof ==="

OUT_A=$(mktemp)
OUT_B=$(mktemp)

# Background both simultaneously — this exercises the race window
msb exec \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/conctest-a \
  "$CONTAINER" -- \
  claude -p "print the word READY and nothing else" \
  >"$OUT_A" 2>&1 &
PID_A=$!

msb exec \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/conctest-b \
  "$CONTAINER" -- \
  claude -p "print the word READY and nothing else" \
  >"$OUT_B" 2>&1 &
PID_B=$!

# Wait for both
EXIT_A=0
EXIT_B=0
wait $PID_A || EXIT_A=$?
wait $PID_B || EXIT_B=$?

echo "Agent A exit: $EXIT_A"
echo "Agent B exit: $EXIT_B"

if [[ $EXIT_A -eq 0 ]]; then
  pass "Agent A (conctest-a) exited 0"
else
  fail "Agent A (conctest-a) exited $EXIT_A" "$(cat "$OUT_A" | head -5)"
fi

if [[ $EXIT_B -eq 0 ]]; then
  pass "Agent B (conctest-b) exited 0"
else
  fail "Agent B (conctest-b) exited $EXIT_B" "$(cat "$OUT_B" | head -5)"
fi

# Check stdout contains READY
A_HAS_READY=false
if grep -q 'READY' "$OUT_A"; then
  A_HAS_READY=true
  pass "Agent A stdout contains READY"
else
  fail "Agent A stdout does NOT contain READY" "$(cat "$OUT_A" | head -5)"
fi

B_HAS_READY=false
if grep -q 'READY' "$OUT_B"; then
  B_HAS_READY=true
  pass "Agent B stdout contains READY"
else
  fail "Agent B stdout does NOT contain READY" "$(cat "$OUT_B" | head -5)"
fi

# Gate: absence assertions only run when both were live (positive sentinel)
BOTH_READY=false
if [[ "$A_HAS_READY" == "true" && "$B_HAS_READY" == "true" ]]; then
  BOTH_READY=true
fi

# Only assert "no loop" if we have the positive sentinel (both ran and printed READY)
if [[ "$BOTH_READY" == "true" ]]; then
  if _sticky_miss_detected "$OUT_A"; then
    fail "Agent A stdout contains 'configuration file not found' (the clobber bug!)" ""
  else
    pass "Agent A stdout: no 'configuration file not found' loop"
  fi
  if _sticky_miss_detected "$OUT_B"; then
    fail "Agent B stdout contains 'configuration file not found' (the clobber bug!)" ""
  else
    pass "Agent B stdout: no 'configuration file not found' loop"
  fi
else
  echo "  NOTE: Skipping 'no configuration file not found' check — positive sentinel (READY) not established for both agents"
fi

rm -f "$OUT_A" "$OUT_B"

# ---------------------------------------------------------------------------
# Step 2: Isolation proof
# Each session has its own .claude.json; .credentials.json is a symlink to shared
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Isolation proof ==="

# Both .claude.json exist
if cexec test -f /home/agent/.claude-sessions/conctest-a/.claude.json; then
  pass ".claude-sessions/conctest-a/.claude.json exists"
else
  fail ".claude-sessions/conctest-a/.claude.json MISSING"
fi
if cexec test -f /home/agent/.claude-sessions/conctest-b/.claude.json; then
  pass ".claude-sessions/conctest-b/.claude.json exists"
else
  fail ".claude-sessions/conctest-b/.claude.json MISSING"
fi

# They are distinct files (different inodes — since they were seeded from copies, not symlinks)
INODE_A=$(cexec stat -c '%i' /home/agent/.claude-sessions/conctest-a/.claude.json 2>/dev/null || echo "missing-a")
INODE_B=$(cexec stat -c '%i' /home/agent/.claude-sessions/conctest-b/.claude.json 2>/dev/null || echo "missing-b")
if [[ "$INODE_A" != "$INODE_B" && "$INODE_A" != "missing-a" && "$INODE_B" != "missing-b" ]]; then
  pass "conctest-a and conctest-b .claude.json are distinct files (different inodes: $INODE_A vs $INODE_B)"
else
  fail "conctest-a and conctest-b .claude.json have the same inode — NOT isolated!" "inode_a=$INODE_A inode_b=$INODE_B"
fi

# .credentials.json in session A is a symlink pointing to the shared base.
# Possession-only: under non-possession there is no mounted
# /home/agent/.claude/.credentials.json for the session-wrapper to symlink to
# (the wrapper correctly creates the symlink only if the source exists,
# examples/claude/claude-session-wrapper.sh:77-89) — named-skip rather than
# asserting a shared credential that was never posture-eligible to exist.
if [[ "$POSSESSION" != "true" ]]; then
  echo "SKIP (non-possession posture): credential-isolation symlink assertion — no /home/agent/.claude/.credentials.json mounted"
elif cexec test -L /home/agent/.claude-sessions/conctest-a/.credentials.json; then
  CRED_TARGET=$(cexec readlink /home/agent/.claude-sessions/conctest-a/.credentials.json)
  if [[ "$CRED_TARGET" == "/home/agent/.claude/.credentials.json" ]]; then
    pass "conctest-a/.credentials.json symlinks to /home/agent/.claude/.credentials.json (shared)"
  else
    fail "conctest-a/.credentials.json symlink target unexpected" "got: $CRED_TARGET"
  fi
else
  fail "conctest-a/.credentials.json is NOT a symlink (expected shared credential symlink)"
fi

# ---------------------------------------------------------------------------
# Step 3a: MCP-carryover proof — real set-equality vs base snapshot (PRIMARY)
# The snapshot ~/.claude/.claude.json.seed (taken at init time while the mount
# was intact) carries mcpServers + oauthAccount. A session seeded from it must
# carry the same content as the snapshot.
#
# The 4 claude.ai connectors in this env are account-managed and flow through
# oauthAccount (not mcpServers, which may legitimately be empty). So:
#   - mcpServers: set-equality between snapshot and session (may both be empty)
#   - oauthAccount: must be present and non-null in BOTH snapshot and session
#     (this is the non-vacuous carryover signal — if absent, seed failed to carry
#     the connectors that power the actual claude.ai MCP servers)
# Non-vacuous: if oauthAccount is absent in the snapshot → FAIL.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3a: MCP-carryover proof (set-equality vs base snapshot) ==="

MCP_SEED_DIR=/home/agent/.claude-sessions/conctest-mcp-setequal

# Possession-only: oauthAccount carries the account-managed claude.ai
# connectors, which only flow through a snapshot taken from a real,
# credentialed ~/.claude.json. Under non-possession there is no guarantee the
# synthesized/carried seed carries an oauthAccount at all (rip-cage-t7cu: a
# fully non-possession cage without a host ~/.claude.json falls back to a
# minimal synthesized seed with no oauthAccount) — named-skip rather than
# asserting a posture-ineligible connector carryover.
if [[ "$POSSESSION" != "true" ]]; then
  echo "SKIP (non-possession posture): oauthAccount/mcpServers carryover assertion — no possession-backed credential snapshot to carry oauthAccount"
else
  # Positive sentinel: the snapshot must exist and be non-empty
  _seed_exists=$(cexec bash -c "[ -f /home/agent/.claude/.claude.json.seed ] && [ -s /home/agent/.claude/.claude.json.seed ] && echo yes || echo no")
  if [[ "$_seed_exists" != "yes" ]]; then
    fail "Step 3a: ~/.claude/.claude.json.seed is absent or empty — R4 snapshot was not taken at init time (prerequisite for set-equality test)" ""
  else
    # Non-vacuous check: oauthAccount must be present in the snapshot (it carries the connectors)
    _base_oauth=$(cexec bash -c "jq -r 'if .oauthAccount then \"present\" else \"absent\" end' /home/agent/.claude/.claude.json.seed 2>/dev/null" || echo "jq-failed")
    if [[ "$_base_oauth" != "present" ]]; then
      fail "Step 3a: snapshot ~/.claude/.claude.json.seed has no oauthAccount — snapshot did not carry account-managed connectors" \
        "oauthAccount: $(cexec bash -c "jq '.oauthAccount // \"null\"' /home/agent/.claude/.claude.json.seed 2>/dev/null" || echo 'jq-failed')"
    else
      # Read MCP server keys from the snapshot (may be empty in this env — that's OK)
      _base_mcp_keys=$(cexec bash -c "jq -r '(.mcpServers // {}) | keys | sort | .[]' /home/agent/.claude/.claude.json.seed 2>/dev/null" || true)
      echo "  Base snapshot: oauthAccount=present, mcpServers keys: [$(echo "$_base_mcp_keys" | tr '\n' ' ' | sed 's/ $//'  )]"

      # Seed a fresh session using the wrapper WITHOUT RC_P1P_JSON_BASE override,
      # so it uses the snapshot (R4 path — ~/.claude/.claude.json.seed).
      cexec rm -rf "$MCP_SEED_DIR"
      msb exec \
        -e CLAUDE_CONFIG_DIR="$MCP_SEED_DIR" \
        "$CONTAINER" -- \
        /usr/local/bin/claude --version >/dev/null 2>&1 || true

      # Assert oauthAccount is present in the seeded session
      _session_oauth=$(cexec bash -c "jq -r 'if .oauthAccount then \"present\" else \"absent\" end' '${MCP_SEED_DIR}/.claude.json' 2>/dev/null" || echo "jq-failed")
      # Assert mcpServers set-equality
      _session_mcp_keys=$(cexec bash -c "jq -r '(.mcpServers // {}) | keys | sort | .[]' '${MCP_SEED_DIR}/.claude.json' 2>/dev/null" || true)

      echo "  Session: oauthAccount=$_session_oauth, mcpServers keys: [$(echo "$_session_mcp_keys" | tr '\n' ' ' | sed 's/ $//')]"

      _3a_ok=true
      if [[ "$_session_oauth" != "present" ]]; then
        fail "Step 3a: seeded session .claude.json has no oauthAccount — seed-by-copy dropped account connectors" \
          "session file: ${MCP_SEED_DIR}/.claude.json"
        _3a_ok=false
      fi
      if [[ "$_base_mcp_keys" != "$_session_mcp_keys" ]]; then
        fail "Step 3a: seeded session mcpServers keys differ from base snapshot" \
          "base: [$(echo "$_base_mcp_keys" | tr '\n' ',')] | session: [$(echo "$_session_mcp_keys" | tr '\n' ',')]"
        _3a_ok=false
      fi
      if [[ "$_3a_ok" == "true" ]]; then
        pass "Step 3a: seeded session carries oauthAccount (non-empty) and mcpServers == base snapshot"
      fi
    fi
  fi
fi

# Cleanup
cexec rm -rf "$MCP_SEED_DIR"

# ---------------------------------------------------------------------------
# Step 3b: MCP-sentinel supplement (deterministic copy proof — kept from 169e102)
# Injects a custom sentinel server into a fixture, seeds a session from it via
# RC_P1P_JSON_BASE, and asserts the sentinel survives. Proves copy-preserves-an-
# arbitrary-server regardless of ambient state; complements 3a's real-connector proof.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3b: MCP-carryover supplement (sentinel injection via RC_P1P_JSON_BASE) ==="

MCP_SENTINEL_KEY="p1p-sentinel-mcp"
MCP_SENTINEL_DIR=/home/agent/.claude-sessions/conctest-mcp-sentinel
MCP_FIXTURE=/tmp/p1p-mcp-fixture.json

# Create the fixture: start from a minimal valid .claude.json, inject the sentinel.
# We use a container-native temp file (not the bind-mounted ~/.claude.json) to avoid
# writing through to the host's live config.
cexec bash -c "
  if [ -f /home/agent/.claude-sessions/conctest-a/.claude.json ]; then
    cp /home/agent/.claude-sessions/conctest-a/.claude.json $MCP_FIXTURE
  else
    echo '{}' > $MCP_FIXTURE
  fi
  jq '.mcpServers[\"$MCP_SENTINEL_KEY\"] = {\"type\": \"stdio\", \"command\": \"echo\", \"args\": [\"sentinel\"]}' \
    $MCP_FIXTURE > ${MCP_FIXTURE}.tmp
  mv ${MCP_FIXTURE}.tmp $MCP_FIXTURE
"

# Positive confirmation: the sentinel must be in the fixture before we seed
_sentinel_in_fixture=$(cexec bash -c "jq -r '.mcpServers | keys[] | select(. == \"$MCP_SENTINEL_KEY\")' $MCP_FIXTURE 2>/dev/null" || true)
if [[ "$_sentinel_in_fixture" != "$MCP_SENTINEL_KEY" ]]; then
  fail "Step 3b: sentinel injection into fixture failed" ""
else
  # Seed a fresh session dir with RC_P1P_JSON_BASE pointing at the fixture
  cexec rm -rf "$MCP_SENTINEL_DIR"
  msb exec \
    -e CLAUDE_CONFIG_DIR="$MCP_SENTINEL_DIR" \
    -e RC_P1P_JSON_BASE="$MCP_FIXTURE" \
    "$CONTAINER" -- \
    /usr/local/bin/claude --version >/dev/null 2>&1 || true

  # Assert the sentinel survived the copy into the session dir
  _sentinel_in_session=$(cexec bash -c "jq -r '.mcpServers | keys[] | select(. == \"$MCP_SENTINEL_KEY\")' '${MCP_SENTINEL_DIR}/.claude.json' 2>/dev/null" || true)
  if [[ "$_sentinel_in_session" == "$MCP_SENTINEL_KEY" ]]; then
    pass "Step 3b: sentinel '$MCP_SENTINEL_KEY' survived seed-by-copy into session dir"
  else
    fail "Step 3b: sentinel '$MCP_SENTINEL_KEY' NOT in seeded session .claude.json — seed-by-copy broken" \
      "session mcpServers keys: $(cexec bash -c "jq -r '(.mcpServers // {}) | keys[]' '${MCP_SENTINEL_DIR}/.claude.json' 2>/dev/null" || echo 'jq-failed')"
  fi
fi

# Cleanup
cexec rm -rf "$MCP_SENTINEL_DIR"
cexec rm -f "$MCP_FIXTURE"

# ---------------------------------------------------------------------------
# Step 3c: R4 regression guard — snapshot-seeded despite broken live mount
# Proves the fix: when the live ~/.claude.json is unavailable (simulates the
# broken virtiofs mount handle), the wrapper seeds from ~/.claude/.claude.json.seed
# and NOT from the broken live path, producing a non-empty session .claude.json
# that carries the same MCP server set as the snapshot.
#
# Simulation: override the wrapper's fallback with a non-existent path via
# RC_P1P_JSON_BASE=/nonexistent/path — this bypasses both the snapshot and the
# live mount in the precedence chain... WAIT — that hits RC_P1P_JSON_BASE first,
# which in the wrapper is test-hook-highest-priority, not the snapshot path.
#
# Correct simulation: the wrapper now resolves: RC_P1P_JSON_BASE > snapshot > live.
# To simulate "live mount broken, snapshot present": we set NO RC_P1P_JSON_BASE
# override (so wrapper uses snapshot) and confirm the session is non-empty with
# correct servers. The R4 fix is that the wrapper's DEFAULT production path now
# uses the snapshot, not the live mount.
#
# To prove the snapshot is the source (not the live mount): temporarily override
# the live mount path only by ensuring the snapshot differs from what the live
# mount would give (inject a guard key into the snapshot, seed, assert guard key
# present — if the live mount were used, the guard key would be absent).
#
# Gated on: snapshot present and non-empty (positive sentinel).
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3c: R4 regression guard (snapshot-seeded despite absent live mount) ==="

R4_GUARD_DIR=/home/agent/.claude-sessions/conctest-r4-guard
R4_GUARD_SNAPSHOT=/tmp/p1p-r4-snapshot-fixture.json
R4_GUARD_KEY="p1p-r4-guard-key"

# Gate: snapshot must exist and be non-empty
_r4_seed_ok=$(cexec bash -c "[ -f /home/agent/.claude/.claude.json.seed ] && [ -s /home/agent/.claude/.claude.json.seed ] && echo yes || echo no")
if [[ "$_r4_seed_ok" != "yes" ]]; then
  fail "Step 3c: ~/.claude/.claude.json.seed absent/empty — R4 regression guard cannot run (snapshot prerequisite not met)" ""
else
  # Save a clean backup of the snapshot FIRST (before any modification).
  # Then inject the guard key into the REAL snapshot.
  # Seeding WITHOUT RC_P1P_JSON_BASE → wrapper uses the real snapshot path.
  # Guard key present in session ⟹ snapshot was used (not the live mount).
  # Restore the clean backup to the snapshot at the end.
  R4_ORIGINAL_BACKUP=/tmp/p1p-r4-original-backup.json
  cexec cp /home/agent/.claude/.claude.json.seed "$R4_ORIGINAL_BACKUP"
  cexec bash -c "
    jq '.mcpServers[\"$R4_GUARD_KEY\"] = {\"type\": \"stdio\", \"command\": \"echo\", \"args\": [\"r4-guard\"]}' \
      $R4_ORIGINAL_BACKUP > ${R4_GUARD_SNAPSHOT}
    cp ${R4_GUARD_SNAPSHOT} /home/agent/.claude/.claude.json.seed
  "

  # Positive sentinel: guard key must be in the modified snapshot
  _guard_in_snapshot=$(cexec bash -c "jq -r '.mcpServers | keys[] | select(. == \"$R4_GUARD_KEY\")' /home/agent/.claude/.claude.json.seed 2>/dev/null" || true)
  if [[ "$_guard_in_snapshot" != "$R4_GUARD_KEY" ]]; then
    fail "Step 3c: guard key injection into snapshot failed — cannot run R4 guard" ""
    # Restore original before continuing
    cexec cp "$R4_ORIGINAL_BACKUP" /home/agent/.claude/.claude.json.seed
  else
    # Seed a fresh session with NO RC_P1P_JSON_BASE override.
    # The wrapper resolves: snapshot (~/.claude/.claude.json.seed) takes precedence
    # over the live mount. Guard key present ⟹ snapshot was used.
    cexec rm -rf "$R4_GUARD_DIR"
    msb exec \
      -e CLAUDE_CONFIG_DIR="$R4_GUARD_DIR" \
      "$CONTAINER" -- \
      /usr/local/bin/claude --version >/dev/null 2>&1 || true

    # Assert: session .claude.json exists and is non-empty
    _r4_session_nonempty=$(cexec bash -c "[ -s '${R4_GUARD_DIR}/.claude.json' ] && echo yes || echo no")
    if [[ "$_r4_session_nonempty" != "yes" ]]; then
      fail "Step 3c: R4 guard — session .claude.json is absent or empty (seeding failed entirely)" ""
    else
      # Assert: guard key is present (proves snapshot was the seed source)
      _guard_in_session=$(cexec bash -c "jq -r '.mcpServers | keys[] | select(. == \"$R4_GUARD_KEY\")' '${R4_GUARD_DIR}/.claude.json' 2>/dev/null" || true)
      if [[ "$_guard_in_session" == "$R4_GUARD_KEY" ]]; then
        pass "Step 3c: R4 regression guard — session seeded from snapshot (guard key present), not live mount"
      else
        fail "Step 3c: R4 guard — guard key '$R4_GUARD_KEY' absent from session .claude.json; wrapper may have fallen to live mount or empty seed" \
          "session keys: $(cexec bash -c "jq -r '(.mcpServers // {}) | keys[]' '${R4_GUARD_DIR}/.claude.json' 2>/dev/null" || echo 'jq-failed')"
      fi
    fi

    # Restore the original clean snapshot (without guard key)
    cexec cp "$R4_ORIGINAL_BACKUP" /home/agent/.claude/.claude.json.seed
  fi
fi

# Cleanup
cexec rm -rf "$R4_GUARD_DIR"
cexec rm -f "$R4_GUARD_SNAPSHOT"
cexec rm -f "${R4_ORIGINAL_BACKUP:-/tmp/p1p-r4-original-backup-missing.json}"

# ---------------------------------------------------------------------------
# Step 4: No-leftover-in-shared-root guard
# After concurrent run, no session-attributable files should appear under ~/.claude
# beyond what was there before.
# Gated on: BOTH_READY (positive sentinel — both agents ran)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: No-leftover-in-shared-root guard ==="

if [[ "$BOTH_READY" == "true" ]]; then
  AFTER_FILES=$(_shared_root_files)
  NEW_FILES=$(comm -13 <(echo "$BEFORE_FILES") <(echo "$AFTER_FILES"))
  if [[ -z "$NEW_FILES" ]]; then
    pass "No unexpected files added to shared ~/.claude root after concurrent runs"
  else
    fail "New files appeared in shared ~/.claude root after concurrent runs" "new files: $NEW_FILES"
  fi
else
  echo "  NOTE: Skipping no-leftover check — positive sentinel not established (both READY required)"
fi

# ---------------------------------------------------------------------------
# Step 5: Single-agent no-regression
# One-agent claude -p still succeeds
# Also verify auth-bootstrap intact: EITHER the live ~/.claude.json mount OR
# its ~/.claude/.claude.json.seed snapshot is present and non-empty (see the
# classification comment below — mirrors cli/doctor.sh's HEALTHY/SEEDED/DEAD
# model, not a stricter invariant of this test file's own invention).
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Single-agent no-regression ==="

OUT_SINGLE=$(mktemp)
EXIT_SINGLE=0
msb exec \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/conctest-singleagent \
  "$CONTAINER" -- \
  claude -p "print the word READY and nothing else" \
  >"$OUT_SINGLE" 2>&1 || EXIT_SINGLE=$?

if [[ $EXIT_SINGLE -eq 0 ]]; then
  pass "Single-agent claude -p exited 0"
else
  fail "Single-agent claude -p exited $EXIT_SINGLE" "$(cat "$OUT_SINGLE" | head -5)"
fi

if grep -q 'READY' "$OUT_SINGLE"; then
  pass "Single-agent stdout contains READY"
else
  fail "Single-agent stdout does NOT contain READY" "$(cat "$OUT_SINGLE" | head -5)"
fi

# Auth-bootstrap check: init-rip-cage.sh maintains TWO valid carriers of
# auth-bootstrap state -- the live ~/.claude.json mount and its
# ~/.claude/.claude.json.seed snapshot. Asserting ~/.claude.json
# unconditionally is a FALSE FAILURE whenever only the seed carrier exists
# (rip-cage-7atw.22 item 4) -- that unconditional check IS the bug this item
# exists to fix, not coverage to preserve (round-3 review correction: an
# earlier round of this fix treated the old assertion's strictness as
# something to keep; the strictness itself was the bug).
#
# Pass/fail boundary: live-ok OR seed-ok. Matches cli/doctor.sh's SEEDED
# classification -- "benign by design ... zero functional impact": init
# snapshots the mount once at boot while intact, and every runtime consumer
# reads the snapshot, never the live mount again, so a present seed means
# auth-bootstrap genuinely IS intact regardless of whether the live handle
# is currently healthy. This assertion's job is "is auth-bootstrap state
# present" -- NOT "was the mount composed correctly," which is a DIFFERENT
# question needing a DIFFERENT oracle (Step 5b below, kept separate on
# purpose: round-3 review found that folding a mount-composed check into
# THIS branch's pass/fail boundary produces no new coverage at all --
# algebraically `(mount-present AND (live-ok OR seed-ok)) OR (mount-absent
# AND seed-ok)` reduces to plain `live-ok OR seed-ok` -- while ALSO risking
# exactly the false-failure this item was filed to fix, if the mount-check
# were ever tightened back into a gate here).
#
# The mount-composed signal (/proc/mounts -- empirically confirmed: a
# carried-mount cage's /proc/mounts contains a line whose field 2 is
# exactly /home/agent/.claude.json; cli/up.sh:704-711 only adds the -v arg
# when the host file exists at cage-creation time) is kept here PURELY for
# labeling/observability -- distinguishing "mount was composed, then went
# dead" (SEEDED) from "no mount was ever composed" (pure-synthesized) in
# the output is worth having even though it does not move the pass/fail
# boundary. CLAUDE_JSON_MOUNTED is also reused by Step 5b below, which DOES
# use it as a gate -- for a different assertion, against a different oracle.
if cexec bash -c 'grep -q " /home/agent/.claude.json " /proc/mounts'; then
  CLAUDE_JSON_MOUNTED=true
  echo "  .claude.json mount-table entry: present (mount was composed at cage creation)"
else
  CLAUDE_JSON_MOUNTED=false
  echo "  .claude.json mount-table entry: absent (no host ~/.claude.json at cage creation)"
fi

if cexec test -s /home/agent/.claude.json; then
  if [[ "$CLAUDE_JSON_MOUNTED" == "true" ]]; then
    pass "Base ~/.claude.json present and non-empty (HEALTHY per cli/doctor.sh's classification)"
  else
    pass "Base ~/.claude.json present and non-empty (no mount-table entry found, but the live file itself is present and non-empty)"
  fi
elif cexec test -s /home/agent/.claude/.claude.json.seed; then
  if [[ "$CLAUDE_JSON_MOUNTED" == "true" ]]; then
    pass "Mount composed but live handle is dead/empty; seed .claude/.claude.json.seed present and non-empty (SEEDED per cli/doctor.sh's classification — benign by design, runtime reads the snapshot)"
  else
    pass "Seed .claude/.claude.json.seed present and non-empty (pure-synthesized posture; auth-bootstrap carried via synthesized seed, no live mount was ever composed)"
  fi
else
  fail "Neither ~/.claude.json nor ~/.claude/.claude.json.seed is present and non-empty — auth-bootstrap is genuinely broken (DEAD per cli/doctor.sh's classification)"
fi

rm -f "$OUT_SINGLE"

# ---------------------------------------------------------------------------
# Step 5b: Mount-composition regression guard (round-3 review — the
# coverage the round-2 reviewer was right to want restored, with the
# correct oracle this time)
#
# Step 5 above answers "is auth-bootstrap state present" (satisfied by
# EITHER carrier — correct, per doctor.sh's SEEDED semantics, and NOT
# re-litigated here). This is a DIFFERENT assertion: "did rc's mount-
# composition code do what the HOST state says it should have done." The
# only oracle that can see a mount-composition regression is host state,
# because THIS test runs on the host (not just in-cage) -- host state is
# ground truth for what SHOULD have been mounted at cage-creation time
# (cli/up.sh:704-711 only adds the ~/.claude.json -v arg when
# `[[ -f "${HOME}/.claude.json" ]]` at `rc up` time; mounts are fixed at
# creation, never re-evaluated on resume).
#
# Constructible both ways -- unlike a mount-composed check folded into Step
# 5's own boundary (shown above to algebraically add no new fail path
# beyond "neither carrier"), this one has a genuine, distinct red case:
#   host ~/.claude.json present + mount entry present -> pass (composed as expected)
#   host ~/.claude.json absent  + mount entry absent  -> pass (nothing to compose)
#   host ~/.claude.json present + mount entry ABSENT  -> FAIL LOUD: a
#     genuine mount-composition regression -- host state says this cage
#     should carry a live mount and the running cage has no such entry.
#   host ~/.claude.json absent  + mount entry present -> also reported loud
#     (not silently accepted): under normal `rc up` semantics this can't
#     happen (nothing without a host source gets mounted), so if it's ever
#     observed, something about this signal or this cage is anomalous and
#     deserves attention rather than a silent pass.
#
# Caveat: reads $HOME on the machine running THIS test script, not
# necessarily the $HOME that created $CONTAINER. Matches the common case
# (operator runs this test against a cage they just `rc up`'d in the same
# shell); a container resolved via RC_TEST_CONTAINER from a different $HOME
# would need that $HOME exported here too.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5b: Mount-composition regression guard (host state vs mount table) ==="

_host_claude_json_present=false
if [[ -f "${HOME}/.claude.json" && -s "${HOME}/.claude.json" ]]; then
  _host_claude_json_present=true
fi
echo "  Host \${HOME}/.claude.json: $([[ "$_host_claude_json_present" == "true" ]] && echo present || echo absent) (HOME=$HOME)"

if [[ "$_host_claude_json_present" == "true" && "$CLAUDE_JSON_MOUNTED" == "true" ]]; then
  pass "Mount-composition guard: host ~/.claude.json present and the cage's mount table shows the entry — composed as expected"
elif [[ "$_host_claude_json_present" == "false" && "$CLAUDE_JSON_MOUNTED" == "false" ]]; then
  pass "Mount-composition guard: host ~/.claude.json absent and the cage's mount table shows no entry — nothing was supposed to be mounted"
elif [[ "$_host_claude_json_present" == "true" && "$CLAUDE_JSON_MOUNTED" == "false" ]]; then
  fail "Mount-composition guard: host ~/.claude.json is present and non-empty, but the cage's mount table has NO /home/agent/.claude.json entry" \
    "genuine mount-composition regression — rc up should have mounted this at cage creation"
else
  fail "Mount-composition guard: host ~/.claude.json is absent, but the cage's mount table SHOWS a /home/agent/.claude.json entry" \
    "anomalous state — a mount with no host source should not be possible under normal rc up semantics"
fi

# ---------------------------------------------------------------------------
# Step 6: Git-author proof
# tmux was un-baked from the image (commit af7a1ce); herdr is the new default
# multiplexer. Mirrors Step 7c's herdr mechanism: set HERDR_SESSION directly
# (no live multiplexer session needed — the zshrc snippet at
# cage/agent/zshrc:170-176 reads HERDR_SESSION straight from the env) and
# drive the commit through an interactive zsh (`zsh -ic`), which sources
# ~/.zshrc and so picks up GIT_AUTHOR_NAME/GIT_COMMITTER_NAME=<handle>.
# Single synchronous docker exec — no send-keys/capture-pane polling needed
# since this is not a detached session, just an interactive login-shell exec.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 6: Git-author proof ==="

GIT_SESSION="conctest-gitauth"
GIT_TEST_DIR="/tmp/conctest-git-$$"

# Create a temp git repo inside the container
cexec bash -c "
  set -e
  rm -rf $GIT_TEST_DIR
  mkdir -p $GIT_TEST_DIR
  cd $GIT_TEST_DIR
  git init
  git config user.email 'test@rip-cage-test.local'
  git config user.name 'test-default-name'
  touch testfile.txt
  git add testfile.txt
"

# Drive the commit through an interactive zsh shell with HERDR_SESSION set
# (TMUX explicitly unset so the zshrc tmux-branch can't shadow the herdr
# branch). Append a sentinel marker so completion is detected deterministically
# rather than by polling/timing.
_git_commit_out=$(msb exec \
  -e HERDR_SESSION="$GIT_SESSION" \
  -e TMUX="" \
  -u agent \
  "$CONTAINER" -- \
  zsh -ic "cd $GIT_TEST_DIR && git commit -m 'test-commit-from-agent'; echo GIT_COMMIT_DONE_$$" 2>&1)

_commit_landed=false
if echo "$_git_commit_out" | grep -q "GIT_COMMIT_DONE_$$"; then
  _commit_landed=true
fi

if [[ "$_commit_landed" != "true" ]]; then
  fail "Git-author: commit sentinel not detected — herdr (zsh -ic HERDR_SESSION) setup failed" "$(echo "$_git_commit_out" | head -5)"
fi

# Read git log to verify author name (deterministic file read, commit is confirmed present)
GIT_LOG=$(cexec bash -c "cd $GIT_TEST_DIR && git log -1 --format='%an|%ae' 2>/dev/null" || echo "git-log-failed")

AUTHOR_NAME=$(echo "$GIT_LOG" | cut -d'|' -f1)
AUTHOR_EMAIL=$(echo "$GIT_LOG" | cut -d'|' -f2)

echo "  git log -1 author: name='$AUTHOR_NAME' email='$AUTHOR_EMAIL'"

if [[ "$AUTHOR_NAME" == "$GIT_SESSION" ]]; then
  pass "Git author name = herdr session handle '$GIT_SESSION'"
else
  fail "Git author name = '$AUTHOR_NAME' (expected '$GIT_SESSION' from GIT_AUTHOR_NAME env)" ""
fi

# Email should be the human's (not agent-specific) — the gitconfig email stays unchanged
# We can't check the exact email here, but we can verify it's non-empty and != the session name
if [[ -n "$AUTHOR_EMAIL" && "$AUTHOR_EMAIL" != "$GIT_SESSION" ]]; then
  pass "Git author email is human's email (non-empty, not the session handle): '$AUTHOR_EMAIL'"
else
  fail "Git author email unexpected" "got='$AUTHOR_EMAIL' (expected human email, not session handle)"
fi

# Cleanup
cexec rm -rf "$GIT_TEST_DIR"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL (Fix 1 — detector validation via a manufactured trigger
# state): this block does NOT reproduce a genuine concurrent race — the
# setup below manufactures the sticky-miss trigger state directly (backup
# present, .claude.json absent) before either process runs, so the
# "configuration file not found" symptom is satisfiable by a SINGLE process;
# concurrency is not load-bearing for it (round-2 review Ruling 3 — an
# earlier version of this header/pass-string overclaimed "at least one
# process must experience the clobber" / "harness CAN detect the race bug",
# implying a real race was reproduced and won here, which is not what this
# block demonstrates or needs to demonstrate). What it DOES genuinely
# demonstrate, and what is actually useful: given the documented sticky-miss
# trigger state, the REAL claude binary emits the "configuration file not
# found" message, and the harness's own detector (_sticky_miss_detected,
# the same function Step 1 uses) recognizes it. Two real processes are run
# concurrently anyway (matching the actual production shape this control is
# modeled on — two agents racing a shared, non-wrapper-isolated config dir),
# but the assertion below is a detector-validation, not a race
# reproduction — labeled as such throughout.
#
# The shared dir is seeded with a backups/ entry (the documented sticky-miss trigger:
# .claude.json absent + backup present = loop). Both processes use the REAL /usr/bin/claude
# binary — NOT the wrapper, which would fix the dir.
#
# Hard assertion: FAILURES++ unless the mechanism-specific clobber evidence is
# present. There is NO soft-pass branch. (Fix 1)
#
# Posture (rip-cage-7atw.22 item 4, second half): the backup seed used to come
# from the live ~/.claude.json, which genuinely does not exist under
# pure-synthesized posture (cp fails with "cannot stat", the exact symptom
# the bead named) -- a vacuous setup failure that this control's own "no
# soft-pass" framing was never designed to distinguish from a real
# detection miss. Seed the backup from ~/.claude/.claude.json.seed instead:
# the actual guarantee that this file is present and non-empty is init-rip-
# cage.sh's R4 snapshot logic (cage/init/init-rip-cage.sh:~490-501), which
# runs on every successful init and either copies the live mount, preserves
# an existing seed, or synthesizes a minimal placeholder -- not Step 5 above,
# whose HEALTHY branch never re-checks the seed at all (it only checks it in
# the SEEDED/DEAD fallback, so Step 5 passing does not by itself guarantee a
# seed exists). It is valid config-shaped JSON either way, so the sticky-miss
# trigger condition (.claude.json absent + backup present) is reproduced
# identically regardless of posture. The .credentials.json symlink is gated
# on the file's existing POSSESSION signal (computed once, top of file) --
# the same signal Step 2's identical symlink assertion already uses --
# rather than inventing a second posture check: under non-possession there
# is nothing to link (mirrors the wrapper's own behavior, examples/claude/
# claude-session-wrapper.sh:77-89), and the race this control proves is
# about the .claude.json sticky-miss loop, not credentials.
#
# Adversarial-review findings closed here (rip-cage-7atw.22, round 2):
#   F5 (setup silently tolerated): the seeding step runs inside `cexec bash -c
#       "set -e ..."` -- `set -e` only aborts the GUEST shell; the OUTER
#       cexec call's own exit status was never checked (this file runs
#       `set -uo pipefail`, no `-e`), so a failed `cp`/`mkdir` left an
#       unarmed trigger and the control still ran and could still pass via
#       one of the OR'd conditions below. Now captured explicitly and
#       failed loud, plus a positive-sentinel check that the backup file
#       itself actually landed before the race is allowed to run.
#   F6 (satisfiable by non-clobber causes): bare non-zero exit and bare
#       "shared .claude.json missing" were each independently sufficient to
#       report detection. Both are true for reasons that have NOTHING to do
#       with the clobber: exit is non-zero on ANY auth failure or on the
#       30s `timeout` firing for any reason, and "missing after the run" is
#       true BY CONSTRUCTION (SHARED_DIR is seeded with no .claude.json --
#       that is the trigger state itself, not evidence anything happened
#       during the run). The ONLY evidence that actually identifies the
#       sticky-miss mechanism specifically is the "configuration file not
#       found / restore manually" message. That message is now the SOLE
#       pass criterion; exit codes and the missing/empty-file check are
#       still gathered and printed as corroborating detail but can no
#       longer flip NEG_CLOBBER on their own.
#   Working-auth precondition: without confirmed-working auth, a non-zero
#       exit or absent output is indistinguishable from an auth failure --
#       gated below on BOTH_READY (Step 1's own signal: both concurrent
#       claude -p calls showed READY in their merged stdout/stderr text —
#       independent of exit code, lines ~193-213), reusing an existing
#       signal in this file rather than inventing a new auth probe. Both
#       deviations from a stricter "exited 0 AND showed READY" precondition
#       err toward red (a text-only match is a LOOSER bar to fail, not a
#       looser bar to pass, so this cannot manufacture a false precondition-
#       met). If auth was never confirmed working, this control cannot
#       honestly claim anything and fails loud on the missing precondition
#       instead of silently passing.
# ---------------------------------------------------------------------------
echo ""
echo "=== NEGATIVE CONTROL: sticky-miss detector validation (manufactured trigger state, ONE shared config dir) ==="

if [[ "$BOTH_READY" != "true" ]]; then
  fail "NEGATIVE CONTROL: working-auth precondition not met — Step 1's two concurrent claude -p calls did not both show READY in their output (BOTH_READY: a merged-stdout/stderr text match, independent of exit code), so a clobber cannot be distinguished from an auth failure here" \
    "this control requires confirmed-working auth; re-run against a cage where Step 1 passes"
else
  SHARED_DIR=/home/agent/.claude-sessions/conctest-shared
  cexec rm -rf "$SHARED_DIR"
  _neg_setup_out=$(cexec bash -c "
    set -e
    mkdir -p ${SHARED_DIR}/backups
    # .claude.json is ABSENT — this is the exact bug trigger state.
    # A backup IS present (the documented sticky-miss condition):
    # when Claude finds a backup but no .claude.json, it loops with
    # 'configuration file not found' instead of recreating the file.
    # Seeded from the seed snapshot (guaranteed by init-rip-cage.sh's R4
    # logic), not the live ~/.claude.json (absent under pure-synthesized
    # posture).
    cp /home/agent/.claude/.claude.json.seed '${SHARED_DIR}/backups/.claude.json.backup.1780000000000'
    if [ '$POSSESSION' = 'true' ]; then
      ln -sfn /home/agent/.claude/.credentials.json ${SHARED_DIR}/.credentials.json
    fi
  " 2>&1)
  _neg_setup_rc=$?

  if [[ $_neg_setup_rc -ne 0 ]]; then
    fail "NEGATIVE CONTROL: setup failed (exit $_neg_setup_rc) — the sticky-miss trigger was never armed, so this run proves nothing" "$_neg_setup_out"
  elif ! cexec test -s "${SHARED_DIR}/backups/.claude.json.backup.1780000000000"; then
    fail "NEGATIVE CONTROL: setup reported success but the backup file is absent/empty — the sticky-miss trigger was never armed" ""
  else
    OUT_NEG_X=$(mktemp)
    OUT_NEG_Y=$(mktemp)

    # Background BOTH against the SAME shared dir — real binary, no wrapper isolation.
    msb exec \
      -e CLAUDE_CONFIG_DIR="$SHARED_DIR" \
      "$CONTAINER" -- \
      timeout 30 /usr/bin/claude -p "print the word READY and nothing else" \
      >"$OUT_NEG_X" 2>&1 &
    PID_NEG_X=$!

    msb exec \
      -e CLAUDE_CONFIG_DIR="$SHARED_DIR" \
      "$CONTAINER" -- \
      timeout 30 /usr/bin/claude -p "print the word READY and nothing else" \
      >"$OUT_NEG_Y" 2>&1 &
    PID_NEG_Y=$!

    NEG_EXIT_X=0
    NEG_EXIT_Y=0
    wait $PID_NEG_X || NEG_EXIT_X=$?
    wait $PID_NEG_Y || NEG_EXIT_Y=$?

    echo "  Shared-dir process X exit: $NEG_EXIT_X"
    echo "  Shared-dir process Y exit: $NEG_EXIT_Y"
    echo "  Process X output (first 3 lines):"
    head -3 "$OUT_NEG_X" | sed 's/^/    /'
    echo "  Process Y output (first 3 lines):"
    head -3 "$OUT_NEG_Y" | sed 's/^/    /'

    # PRIMARY evidence — the ONLY thing that identifies the sticky-miss
    # clobber mechanism specifically, so it is the sole pass criterion (F6).
    # Calls the SAME _sticky_miss_detected function Step 1's detector uses
    # (round-2 review Ruling 2, acceptance criterion 4) rather than its own
    # copy of the pattern: a copied-and-widened pattern is exactly how this
    # control drifted from the detector it exists to validate last round
    # (case-insensitive, two extra alternations with no anchor in real
    # emitted text) — a shared function is what keeps them from drifting
    # apart again.
    NEG_CLOBBER=false
    if _sticky_miss_detected "$OUT_NEG_X"; then
      NEG_CLOBBER=true
      echo "  Evidence (PRIMARY): process X output contains config-not-found message"
    fi
    if _sticky_miss_detected "$OUT_NEG_Y"; then
      NEG_CLOBBER=true
      echo "  Evidence (PRIMARY): process Y output contains config-not-found message"
    fi

    # Corroborating-only evidence — printed for diagnostic value, but NEVER
    # by itself sets NEG_CLOBBER: a non-zero exit is equally explained by an
    # auth failure or the 30s timeout firing, and "shared .claude.json
    # missing" is true BY CONSTRUCTION (the seeded trigger state has no
    # .claude.json at all, regardless of whether the race ever ran).
    if [[ $NEG_EXIT_X -ne 0 ]]; then
      echo "  Evidence (corroborating, non-decisive): process X exited $NEG_EXIT_X (non-zero)"
    fi
    if [[ $NEG_EXIT_Y -ne 0 ]]; then
      echo "  Evidence (corroborating, non-decisive): process Y exited $NEG_EXIT_Y (non-zero)"
    fi
    if ! cexec test -f "${SHARED_DIR}/.claude.json" 2>/dev/null; then
      echo "  Evidence (corroborating, non-decisive): shared .claude.json is missing after concurrent run"
    elif cexec bash -c "[ ! -s '${SHARED_DIR}/.claude.json' ]" 2>/dev/null; then
      echo "  Evidence (corroborating, non-decisive): shared .claude.json is empty/truncated after concurrent run"
    fi

    if [[ "$NEG_CLOBBER" == "true" ]]; then
      pass "NEGATIVE CONTROL: claude emitted the sticky-miss message given the seeded trigger state, and the harness's own detector (_sticky_miss_detected) sees it — detector validated"
    else
      # Neither process's output showed the sticky-miss message — the
      # harness's detector would not have caught this. This is a HARD
      # FAILURE: no soft-pass, and corroborating-only evidence (exit codes,
      # missing-file) does NOT substitute for the mechanism-specific message.
      fail "NEGATIVE CONTROL: neither process showed the config-not-found sticky-miss message — the harness's detector (_sticky_miss_detected) is NOT validated by this run" \
        "X_exit=$NEG_EXIT_X Y_exit=$NEG_EXIT_Y — fix the control"
    fi

    rm -f "$OUT_NEG_X" "$OUT_NEG_Y"
  fi
fi

# ---------------------------------------------------------------------------
# Step 7: Multiplexer-agnostic config-dir derivation proof (rip-cage-1f59.4)
#
# Unit-tests the wrapper's three-way derivation logic by seeding sessions
# via the identity env vars directly (no full cage up required):
#
#   7a. none (no multiplexer identity)     → CLAUDE_CONFIG_DIR = ~/.claude-sessions/default
#   7b. herdr live-shell ($HERDR_SESSION,  → CLAUDE_CONFIG_DIR = ~/.claude-sessions/<HERDR_SESSION>
#       via zshrc export in an interactive   (zshrc snippet's export branch, live shell)
#       shell)
#   7c. herdr direct ($HERDR_SESSION set   → CLAUDE_CONFIG_DIR = ~/.claude-sessions/<HERDR_SESSION>
#       on the wrapper invocation)            (wrapper's own derivation branch)
#       GATING: must PASS, not skip (D7 RESOLVED by rip-cage-1f59.5: HERDR_SESSION confirmed)
#
# tmux was un-baked from the image (commit af7a1ce); herdr is the new default
# multiplexer, so 7b — originally the tmux live-session variant — is
# re-pointed to herdr (rip-cage-7atw.4). 7b and 7c intentionally exercise two
# different code paths (see the comment above 7b) rather than duplicating
# each other's mechanism.
#
# Method: invoke the wrapper via --version (cheap, triggers seeding) with the
# identity env vars manipulated, then read the seeded session dirs to confirm.
# Cleanup stale test dirs first.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 7: Multiplexer-agnostic config-dir derivation (none/herdr-live-shell/herdr-direct) ==="

MUX_TEST_BASE=/home/agent/.claude-sessions

# Cleanup stale derivation test dirs
cexec rm -rf "${MUX_TEST_BASE}/mux-test-default"
cexec rm -rf "${MUX_TEST_BASE}/mux-test-herdr-live"
cexec rm -rf "${MUX_TEST_BASE}/mux-test-herdr-session"

# --- 7a: none (no multiplexer identity) → default fallback ---
# Unset TMUX and HERDR_SESSION; unset CLAUDE_CONFIG_DIR so wrapper derives.
# The wrapper's else-branch writes to ~/.claude-sessions/default.
# We give it a unique seeded dir name by using a pre-created empty dir trick:
# Simply seed via --version and confirm ~/.claude-sessions/default is populated.
#
# Note: 'default' is the shared fallback — we must clean it up before and
# check for the .claude.json presence after (idempotent seeding means if it
# already exists we just confirm presence).
cexec rm -rf "${MUX_TEST_BASE}/default"
msb exec -u agent \
  -e TMUX="" \
  -e HERDR_SESSION="" \
  "$CONTAINER" -- \
  /usr/local/bin/claude --version >/dev/null 2>&1 || true

if cexec test -f "${MUX_TEST_BASE}/default/.claude.json"; then
  pass "Step 7a: none multiplexer → CLAUDE_CONFIG_DIR=~/.claude-sessions/default (seeded)"
else
  fail "Step 7a: none multiplexer — ~/.claude-sessions/default/.claude.json not found (wrapper fallback broken)"
fi

# --- 7b: herdr live-shell derivation ($HERDR_SESSION set) → per-session isolation ---
# tmux was un-baked from the image (commit af7a1ce); herdr is the new default
# multiplexer, so this step is re-pointed to herdr (mirrors Step 6 and Step 7c).
#
# Distinct from Step 7c: 7c invokes the claude-session-wrapper.sh binary
# directly with HERDR_SESSION set on the docker-exec env (proving the
# wrapper's OWN derivation branch, cage/substrate/claude-session-wrapper.sh
# case 3). This step instead drives an interactive zsh (`zsh -ic`, sources
# ~/.zshrc) with HERDR_SESSION set, proving the OTHER code path — the zshrc
# snippet at cage/agent/zshrc:170-176 that exports CLAUDE_CONFIG_DIR into a
# live shell's environment (what an actual herdr session's shell would
# inherit) — then confirms `claude` inside that shell seeds the same
# HERDR_SESSION-derived config dir.
MUX_HERDR_LIVE_SESSION="mux-test-herdr-live"
cexec rm -rf "${MUX_TEST_BASE}/${MUX_HERDR_LIVE_SESSION}"

_mux_herdr_live_out=$(msb exec \
  -e HERDR_SESSION="$MUX_HERDR_LIVE_SESSION" \
  -e TMUX="" \
  -u agent \
  "$CONTAINER" -- \
  zsh -ic "/usr/local/bin/claude --version > /dev/null 2>&1; echo MUX_HERDR_LIVE_DONE_$$" 2>&1)

if ! echo "$_mux_herdr_live_out" | grep -q "MUX_HERDR_LIVE_DONE_$$"; then
  fail "Step 7b: herdr live-shell sentinel not detected — zsh -ic (zshrc sourcing) failed" "$(echo "$_mux_herdr_live_out" | head -5)"
elif cexec test -f "${MUX_TEST_BASE}/${MUX_HERDR_LIVE_SESSION}/.claude.json"; then
  pass "Step 7b: herdr live-shell (zshrc export) → CLAUDE_CONFIG_DIR=~/.claude-sessions/${MUX_HERDR_LIVE_SESSION} (seeded via zshrc-derived HERDR_SESSION)"
else
  fail "Step 7b: herdr live-shell — ~/.claude-sessions/${MUX_HERDR_LIVE_SESSION}/.claude.json not found (zshrc export or wrapper broken)"
fi

cexec rm -rf "${MUX_TEST_BASE}/${MUX_HERDR_LIVE_SESSION}"

# --- 7c: herdr ($HERDR_SESSION set) → per-session isolation (GATING) ---
# D7 RESOLVED by rip-cage-1f59.5: HERDR_SESSION is wrapper-readable per-session env.
# Invoke the wrapper with HERDR_SESSION set (and TMUX unset) and confirm the
# session dir is derived from HERDR_SESSION, NOT the 'default' fallback.
HERDR_TEST_SESSION="mux-test-herdr-session"
cexec rm -rf "${MUX_TEST_BASE}/${HERDR_TEST_SESSION}"
msb exec -u agent \
  -e TMUX="" \
  -e HERDR_SESSION="$HERDR_TEST_SESSION" \
  "$CONTAINER" -- \
  /usr/local/bin/claude --version >/dev/null 2>&1 || true

if cexec test -f "${MUX_TEST_BASE}/${HERDR_TEST_SESSION}/.claude.json"; then
  pass "Step 7c (GATING): herdr multiplexer → CLAUDE_CONFIG_DIR=~/.claude-sessions/${HERDR_TEST_SESSION} (derived from HERDR_SESSION)"
else
  fail "Step 7c (GATING): herdr multiplexer — ~/.claude-sessions/${HERDR_TEST_SESSION}/.claude.json not found (wrapper herdr-branch broken or HERDR_SESSION not honoured)"
fi

# Verify: the herdr-derived dir is NOT the same as the 'default' dir
# (different inodes confirm per-session isolation, not fallback-to-default)
if cexec test -f "${MUX_TEST_BASE}/${HERDR_TEST_SESSION}/.claude.json" && \
   cexec test -f "${MUX_TEST_BASE}/default/.claude.json"; then
  _herdr_inode=$(cexec stat -c '%i' "${MUX_TEST_BASE}/${HERDR_TEST_SESSION}/.claude.json" 2>/dev/null || echo "missing-herdr")
  _default_inode=$(cexec stat -c '%i' "${MUX_TEST_BASE}/default/.claude.json" 2>/dev/null || echo "missing-default")
  if [[ "$_herdr_inode" != "$_default_inode" && "$_herdr_inode" != "missing-herdr" && "$_default_inode" != "missing-default" ]]; then
    pass "Step 7c: herdr session dir is isolated from default dir (different inodes: ${_herdr_inode} vs ${_default_inode})"
  else
    fail "Step 7c (GATING): herdr session dir has same inode as default — NOT isolated (fell back to default instead of per-HERDR_SESSION dir)"
  fi
else
  fail "Step 7c (GATING): cannot run the herdr-vs-default inode isolation proof — one of the .claude.json files is absent (herdr or default dir not seeded); the gating isolation check must not silently skip"
fi

# Cleanup step 7 dirs
cexec rm -rf "${MUX_TEST_BASE}/mux-test-default"
cexec rm -rf "${MUX_TEST_BASE}/${HERDR_TEST_SESSION}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== test-claude-concurrency.sh complete ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All concurrency isolation tests PASSED."
else
  echo "$FAILURES concurrency isolation test(s) FAILED."
fi

exit $FAILURES
