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
# NEGATIVE CONTROL: two concurrent claude -p pointed at ONE config dir MUST show
# corruption/error — proves the harness can detect the bug under isolation failure.
#
# Pre-conditions: docker available; rip-cage:latest built; a running cage exists
# (container name passed as RC_TEST_CONTAINER or auto-detected via docker ps).
#
# Wired into tests/run-host.sh as NEEDS_CONTAINER per ADR-013.
#
# Hard rules (repo lessons):
#   - FAILURES counter + exit $FAILURES at end; no "fail via prose + exit 0".
#   - Every absence assertion is gated on a positive sentinel (both runs exited 0).
#   - set -e is fine here; run-host.sh driver loop does not propagate set -e.

set -uo pipefail

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Guard: skip if docker unavailable
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
# ---------------------------------------------------------------------------
CONTAINER="${RC_TEST_CONTAINER:-}"
if [[ -z "$CONTAINER" ]]; then
  CONTAINER=$(docker ps --format '{{.Names}}' --filter 'ancestor=rip-cage:latest' | head -1)
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
cexec() { docker exec "$CONTAINER" "$@"; }

# Snapshot the list of files directly under ~/.claude (not recursing into subdirs
# we explicitly symlink like projects/sessions — those aren't session-written).
# Returns sorted list of filenames.
_shared_root_files() {
  cexec find /home/agent/.claude -maxdepth 1 -not -name '.' 2>/dev/null | sort || true
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
CRED_MOUNTS_LABEL=$(docker inspect --format '{{ index .Config.Labels "rc.auth.credential-mounts.claude" }}' "$CONTAINER" 2>/dev/null || true)
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
docker exec \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/conctest-a \
  "$CONTAINER" \
  claude -p "print the word READY and nothing else" \
  >"$OUT_A" 2>&1 &
PID_A=$!

docker exec \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/conctest-b \
  "$CONTAINER" \
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
  if grep -q 'configuration file not found' "$OUT_A"; then
    fail "Agent A stdout contains 'configuration file not found' (the clobber bug!)" ""
  else
    pass "Agent A stdout: no 'configuration file not found' loop"
  fi
  if grep -q 'configuration file not found' "$OUT_B"; then
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
      docker exec \
        -e CLAUDE_CONFIG_DIR="$MCP_SEED_DIR" \
        "$CONTAINER" \
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
  docker exec \
    -e CLAUDE_CONFIG_DIR="$MCP_SENTINEL_DIR" \
    -e RC_P1P_JSON_BASE="$MCP_FIXTURE" \
    "$CONTAINER" \
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
    docker exec \
      -e CLAUDE_CONFIG_DIR="$R4_GUARD_DIR" \
      "$CONTAINER" \
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
# Also verify auth-bootstrap intact: ~/.claude.json still exists (for init check)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Single-agent no-regression ==="

OUT_SINGLE=$(mktemp)
EXIT_SINGLE=0
docker exec \
  -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/conctest-singleagent \
  "$CONTAINER" \
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

# Auth-bootstrap check: init-rip-cage.sh reads ~/.claude.json (the base, host-mounted)
# Under uniform D2, the base is still present (it's the host-mounted file)
if cexec test -f /home/agent/.claude.json; then
  pass "Base ~/.claude.json still present (auth-bootstrap not broken by isolation)"
else
  fail "Base ~/.claude.json MISSING — auth-bootstrap may be broken"
fi

rm -f "$OUT_SINGLE"

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
_git_commit_out=$(docker exec \
  -e HERDR_SESSION="$GIT_SESSION" \
  -e TMUX="" \
  -u agent \
  "$CONTAINER" \
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
# NEGATIVE CONTROL (Fix 1 — real concurrent shared-config): Two concurrent
# claude -p processes both pointed at ONE SHARED config dir (bypassing the wrapper
# so isolation is NOT applied). The non-atomic .claude.json rewrite means at least
# one process must experience the clobber (non-zero exit, config-not-found message,
# or missing/empty .claude.json after the run).
#
# The shared dir is seeded with a backups/ entry (the documented sticky-miss trigger:
# .claude.json absent + backup present = loop). Both processes use the REAL /usr/bin/claude
# binary — NOT the wrapper, which would fix the dir.
#
# Hard assertion: if BOTH processes exit 0 AND neither output contains the error AND
# the shared .claude.json is intact, the harness CANNOT detect the race — FAILURES++.
# There is NO soft-pass branch. (Fix 1)
# ---------------------------------------------------------------------------
echo ""
echo "=== NEGATIVE CONTROL: Two concurrent /usr/bin/claude -p on ONE shared config dir (must show clobber) ==="

SHARED_DIR=/home/agent/.claude-sessions/conctest-shared
cexec rm -rf "$SHARED_DIR"
cexec bash -c "
  set -e
  mkdir -p ${SHARED_DIR}/backups
  # .claude.json is ABSENT — this is the exact bug trigger state.
  # A backup IS present (the documented sticky-miss condition):
  # when Claude finds a backup but no .claude.json, it loops with
  # 'configuration file not found' instead of recreating the file.
  cp /home/agent/.claude.json '${SHARED_DIR}/backups/.claude.json.backup.1780000000000'
  ln -sfn /home/agent/.claude/.credentials.json ${SHARED_DIR}/.credentials.json
"

OUT_NEG_X=$(mktemp)
OUT_NEG_Y=$(mktemp)

# Background BOTH against the SAME shared dir — real binary, no wrapper isolation.
docker exec \
  -e CLAUDE_CONFIG_DIR="$SHARED_DIR" \
  "$CONTAINER" \
  timeout 30 /usr/bin/claude -p "print the word READY and nothing else" \
  >"$OUT_NEG_X" 2>&1 &
PID_NEG_X=$!

docker exec \
  -e CLAUDE_CONFIG_DIR="$SHARED_DIR" \
  "$CONTAINER" \
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

# Detect clobber evidence in either process
NEG_CLOBBER=false
if [[ $NEG_EXIT_X -ne 0 ]]; then
  NEG_CLOBBER=true
  echo "  Evidence: process X exited $NEG_EXIT_X (non-zero)"
fi
if [[ $NEG_EXIT_Y -ne 0 ]]; then
  NEG_CLOBBER=true
  echo "  Evidence: process Y exited $NEG_EXIT_Y (non-zero)"
fi
if grep -qi 'configuration file not found\|Claude configuration file\|restore manually' "$OUT_NEG_X" 2>/dev/null; then
  NEG_CLOBBER=true
  echo "  Evidence: process X output contains config-not-found message"
fi
if grep -qi 'configuration file not found\|Claude configuration file\|restore manually' "$OUT_NEG_Y" 2>/dev/null; then
  NEG_CLOBBER=true
  echo "  Evidence: process Y output contains config-not-found message"
fi
# Also check if shared .claude.json ended up missing or empty
if ! cexec test -f "${SHARED_DIR}/.claude.json" 2>/dev/null; then
  NEG_CLOBBER=true
  echo "  Evidence: shared .claude.json is missing after concurrent run"
elif cexec bash -c "[ ! -s '${SHARED_DIR}/.claude.json' ]" 2>/dev/null; then
  NEG_CLOBBER=true
  echo "  Evidence: shared .claude.json is empty/truncated after concurrent run"
fi

if [[ "$NEG_CLOBBER" == "true" ]]; then
  pass "NEGATIVE CONTROL: clobber detected on shared config dir — harness CAN detect the race bug"
else
  # BOTH processes completed cleanly on ONE shared dir — the harness cannot detect the bug.
  # This is a HARD FAILURE: no soft-pass. The harness is vacuous for the race.
  fail "NEGATIVE CONTROL: both processes greened over ONE shared config dir — harness CANNOT detect the clobber race" \
    "X_exit=$NEG_EXIT_X Y_exit=$NEG_EXIT_Y — fix the control"
fi

rm -f "$OUT_NEG_X" "$OUT_NEG_Y"

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
docker exec -u agent \
  -e TMUX="" \
  -e HERDR_SESSION="" \
  "$CONTAINER" \
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

_mux_herdr_live_out=$(docker exec \
  -e HERDR_SESSION="$MUX_HERDR_LIVE_SESSION" \
  -e TMUX="" \
  -u agent \
  "$CONTAINER" \
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
docker exec -u agent \
  -e TMUX="" \
  -e HERDR_SESSION="$HERDR_TEST_SESSION" \
  "$CONTAINER" \
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
