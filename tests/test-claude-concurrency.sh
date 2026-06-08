#!/usr/bin/env bash
# test-claude-concurrency.sh — NEEDS_CONTAINER e2e test
#
# Verifies per-session Claude config isolation (rip-cage-p1p):
#   1. Concurrent-race proof   — two claude -p runs with distinct CLAUDE_CONFIG_DIR
#   2. Isolation proof         — distinct .claude.json files; shared .credentials.json symlink
#   3. MCP-carryover proof     — seed-by-copy preserves base .claude.json content
#   4. No-leftover guard       — no session-written files leaked into shared ~/.claude root
#   5. Single-agent no-regression — one-agent claude -p succeeds; auth-bootstrap intact
#   6. Git-author proof        — detached tmux session sets GIT_AUTHOR_NAME=<handle>
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

# .credentials.json in session A is a symlink pointing to the shared base
if cexec test -L /home/agent/.claude-sessions/conctest-a/.credentials.json; then
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
# Step 3: MCP-carryover proof (Fix 2 — deterministic sentinel injection)
# Design F3.1: seed-by-copy MUST carry mcpServers from the base; an empty seed
# drops them (verified live 2026-06-08 — isolated 'claude mcp list' lost
# mcp-agent-mail / context7 / asana / posthog).
#
# We MANUFACTURE the precondition: create a CONTAINER-NATIVE fixture file (not
# the bind-mounted host ~/.claude.json) with a sentinel mcpServers entry, then
# invoke the wrapper with RC_P1P_JSON_BASE pointing at the fixture. Verify the
# sentinel survives in the seeded session dir's .claude.json.
#
# RC_P1P_JSON_BASE is a test-hook env var that overrides CLAUDE_JSON_BASE in the
# wrapper — production use never sets it. This avoids writing to the host-mounted
# ~/.claude.json (bind mounts from the host; modifying it would affect the user's
# live config).
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: MCP-carryover proof (sentinel injection via RC_P1P_JSON_BASE) ==="

MCP_SENTINEL_KEY="p1p-sentinel-mcp"
MCP_SENTINEL_DIR=/home/agent/.claude-sessions/conctest-mcp-sentinel
MCP_FIXTURE=/tmp/p1p-mcp-fixture.json

# Create the fixture: start from a minimal valid .claude.json, inject the sentinel.
# We use a container-native temp file (not the bind-mounted ~/.claude.json) to avoid
# writing through to the host's live config. The fixture only needs to be a valid JSON
# object with the sentinel mcpServers entry to test that copy-preserves-mcpServers.
# If the session dirs from step 1 exist, we can use conctest-a's .claude.json as the
# base for the fixture (it's a container-native copy already).
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
  fail "MCP-carryover: sentinel injection into fixture failed" ""
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
    pass "MCP-carryover: sentinel '$MCP_SENTINEL_KEY' survived seed-by-copy into session dir"
  else
    fail "MCP-carryover: sentinel '$MCP_SENTINEL_KEY' NOT in seeded session .claude.json — seed-by-copy broken" \
      "session mcpServers keys: $(cexec bash -c "jq -r '(.mcpServers // {}) | keys[]' '${MCP_SENTINEL_DIR}/.claude.json' 2>/dev/null" || echo 'jq-failed')"
  fi
fi

# Cleanup
cexec rm -rf "$MCP_SENTINEL_DIR"
cexec rm -f "$MCP_FIXTURE"

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
# In a detached named tmux session, the zshrc snippet sets GIT_AUTHOR_NAME=<handle>
# Drive a git commit via tmux send-keys; POLL until the commit appears (max 15s),
# then read git log -1 deterministically — no bare sleeps (Fix 3).
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

# Create a detached named tmux session (zshrc will set GIT_AUTHOR_NAME from session name)
# Kill any stale session first
cexec tmux kill-session -t "$GIT_SESSION" 2>/dev/null || true
cexec tmux new-session -d -s "$GIT_SESSION" -c "$GIT_TEST_DIR"

# Poll until the tmux pane is ready (session shell initialized, zshrc sourced).
# Sentinel: a shell prompt visible in the pane within 10s.
_git_s_waited=0
while [[ $_git_s_waited -lt 10 ]]; do
  _pane_content=$(cexec tmux capture-pane -p -t "$GIT_SESSION" 2>/dev/null || true)
  if [[ -n "$_pane_content" ]]; then
    break
  fi
  sleep 1
  _git_s_waited=$((_git_s_waited + 1))
done
# One extra second for zshrc to finish sourcing after the pane appears
sleep 1

# Send a git commit command; GIT_AUTHOR_NAME should be set by zshrc snippet to session name.
# Append a sentinel marker so we can detect completion without relying on timing.
cexec tmux send-keys -t "$GIT_SESSION" "git commit -m 'test-commit-from-agent'; echo GIT_COMMIT_DONE_$$" Enter

# Poll (up to 15s) until the sentinel appears in the pane OR the commit lands in git log.
# Using the tmux-pane sentinel (GIT_COMMIT_DONE) as the primary signal.
_commit_landed=false
_git_c_waited=0
while [[ $_git_c_waited -lt 15 ]]; do
  sleep 1
  _git_c_waited=$((_git_c_waited + 1))
  _pane_after=$(cexec tmux capture-pane -p -t "$GIT_SESSION" 2>/dev/null || true)
  if echo "$_pane_after" | grep -q "GIT_COMMIT_DONE_$$"; then
    _commit_landed=true
    break
  fi
  # Also check git log directly as a fallback
  _log_count=$(cexec bash -c "cd $GIT_TEST_DIR && git log --oneline 2>/dev/null | wc -l" 2>/dev/null || echo "0")
  if [[ "$_log_count" -ge 1 ]]; then
    _commit_landed=true
    break
  fi
done

if [[ "$_commit_landed" != "true" ]]; then
  fail "Git-author: commit sentinel not detected within 15s — tmux send-keys or zshrc setup failed" ""
fi

# Read git log to verify author name (deterministic file read, commit is confirmed present)
GIT_LOG=$(cexec bash -c "cd $GIT_TEST_DIR && git log -1 --format='%an|%ae' 2>/dev/null" || echo "git-log-failed")

AUTHOR_NAME=$(echo "$GIT_LOG" | cut -d'|' -f1)
AUTHOR_EMAIL=$(echo "$GIT_LOG" | cut -d'|' -f2)

echo "  git log -1 author: name='$AUTHOR_NAME' email='$AUTHOR_EMAIL'"

if [[ "$AUTHOR_NAME" == "$GIT_SESSION" ]]; then
  pass "Git author name = tmux session handle '$GIT_SESSION'"
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
cexec tmux kill-session -t "$GIT_SESSION" 2>/dev/null || true
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
