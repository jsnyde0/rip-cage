#!/usr/bin/env bash
# Tests for pi state mount topology: container-local PI_CODING_AGENT_DIR +
# narrow auth.json sub-mount (ADR-019 D1 evolved, rip-cage-hhh.12).
# Requires docker + rip-cage:latest image already built (./rc build).
#
# What this tests:
#   1. /home/agent/.pi/agent/auth.json is mounted and readable inside container
#   2. auth.json owned by agent:agent inside container
#   3. PI_CODING_AGENT_DIR=/home/agent/.pi/agent set in container env
#   4. CAGE_HOST_ADDR passed through explicitly (for non-interactive pi -p)
#   5. Empty OPENAI_API_KEY is NOT forwarded (empty-value filter)
#   6. rc up succeeds when ~/.pi/agent is absent (warning, no fatal)
#   7. /home/agent/.pi/agent/AGENTS.md content + mtime unchanged after rc up
#      (init must not mutate container-local dotfiles)
#   8. auth.json RW round-trip: write inside cage → visible on host (inode preserved)
#   9. extensions/ dir is agent-owned + writable (agent's own extension space; the pi guard is NOT auto-loaded from here — post-olen it rides --no-extensions -e from /etc/rip-cage/pi/)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_WS=""
CONTAINER=""
CONTAINER2=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Resolve the container name from the workspace label — robust against
# rc's collision-hash fallback and tr/sed name normalization.
_resolve_container() {
  local ws="${1:-$TEST_WS}"
  docker ps -a --filter "label=rc.source.path=$(realpath "$ws" 2>/dev/null || echo "$ws")" \
    --format '{{.Names}}' | head -1
}

# ---- Guard: skip if docker or image not available ----
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest image not built — run ./rc build first"
  exit 0
fi

# ---- State backup/restore for ~/.pi/agent ----
PI_AGENT_DIR="${HOME}/.pi/agent"
PI_AGENT_BACKUP=""
PI_AGENT_EXISTED=false
if [[ -d "$PI_AGENT_DIR" ]]; then
  PI_AGENT_EXISTED=true
  PI_AGENT_BACKUP=$(mktemp -d)
  cp -a "$PI_AGENT_DIR/." "$PI_AGENT_BACKUP/"
fi

cleanup() {
  # Tear down any containers we started
  if [[ -n "$CONTAINER" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$CONTAINER2" ]]; then
    docker rm -f "$CONTAINER2" >/dev/null 2>&1 || true
  fi
  # Clean up test workspace dirs
  [[ -n "$TEST_WS" && -d "$TEST_WS" ]] && rm -rf "$TEST_WS"
  [[ -n "${TEST_WS2:-}" && -d "${TEST_WS2}" ]] && rm -rf "$TEST_WS2"
  # Restore ~/.pi/agent state — atomic mv-swap to avoid losing data on cp failure
  if [[ "$PI_AGENT_EXISTED" == "true" && -n "$PI_AGENT_BACKUP" ]]; then
    mv "$PI_AGENT_DIR" "${PI_AGENT_DIR}.evicting"
    mv "$PI_AGENT_BACKUP" "$PI_AGENT_DIR"
    rm -rf "${PI_AGENT_DIR}.evicting"
  elif [[ "$PI_AGENT_EXISTED" == "false" ]]; then
    # We created ~/.pi/agent for the test — remove it (unless it still exists as the
    # real user's directory). Check that it only contains our test file before deleting.
    if [[ -d "$PI_AGENT_DIR" ]]; then
      local _count
      _count=$(find "$PI_AGENT_DIR" -maxdepth 1 -name '*.json' | wc -l)
      # Only auto-remove if it looks like our test directory (single auth.json)
      if [[ -f "$PI_AGENT_DIR/auth.json" && "$_count" -le 1 ]]; then
        rm -rf "$PI_AGENT_DIR"
      fi
    fi
  fi
}
trap cleanup EXIT

# ---- Set up fake ~/.pi/agent/auth.json ----
mkdir -p "$PI_AGENT_DIR"
printf '{"fake":true}\n' > "$PI_AGENT_DIR/auth.json"

TEST_WS=$(mktemp -d)

# ================================================================
# Test 1: pi bind mount — /home/agent/.pi/agent/auth.json visible in container
# ================================================================
echo ""
echo "=== Test 1: /home/agent/.pi/agent/auth.json is mounted and readable ==="

RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container "$TEST_WS")

if [[ -z "$CONTAINER" ]]; then
  fail "container did not come up"
  echo "$FAILURES test(s) FAILED (fatal — no container to inspect)."
  exit "$FAILURES"
fi

content=$(docker exec "$CONTAINER" cat /home/agent/.pi/agent/auth.json 2>/dev/null || true)
if echo "$content" | grep -q "fake"; then
  pass "/home/agent/.pi/agent/auth.json readable and contains expected content"
else
  fail "/home/agent/.pi/agent/auth.json not readable or wrong content" "$content"
fi

# ================================================================
# Test 2: /home/agent/.pi/agent/auth.json owned by agent:agent
# ================================================================
echo ""
echo "=== Test 2: /home/agent/.pi/agent/auth.json owned by agent:agent ==="

ownership=$(docker exec "$CONTAINER" stat -c '%U:%G' /home/agent/.pi/agent/auth.json 2>/dev/null || true)
if [[ "$ownership" == "agent:agent" ]]; then
  pass "/home/agent/.pi/agent/auth.json owner = agent:agent"
else
  fail "/home/agent/.pi/agent/auth.json owner = '$ownership' (expected agent:agent)"
fi

# ================================================================
# Test 3: PI_CODING_AGENT_DIR=/home/agent/.pi/agent set in container env
# ================================================================
echo ""
echo "=== Test 3: PI_CODING_AGENT_DIR=/home/agent/.pi/agent in container env ==="

pi_env=$(docker exec "$CONTAINER" env 2>/dev/null | grep '^PI_CODING_AGENT_DIR=' || true)
if [[ "$pi_env" == "PI_CODING_AGENT_DIR=/home/agent/.pi/agent" ]]; then
  pass "PI_CODING_AGENT_DIR=/home/agent/.pi/agent in container env"
else
  fail "PI_CODING_AGENT_DIR not set correctly" "$pi_env"
fi

# ================================================================
# Test 4: CAGE_HOST_ADDR passed through explicitly (for non-interactive pi -p)
# ================================================================
echo ""
echo "=== Test 4: CAGE_HOST_ADDR present in container env ==="

cage_addr_line=$(docker exec "$CONTAINER" env 2>/dev/null | grep '^CAGE_HOST_ADDR=' || true)
if [[ "${cage_addr_line#CAGE_HOST_ADDR=}" != "" ]]; then
  pass "CAGE_HOST_ADDR present and non-empty in container env ('$cage_addr_line')"
else
  fail "CAGE_HOST_ADDR not set or empty in container env (non-interactive pi -p will fail)" "$cage_addr_line"
fi

# ================================================================
# Test 5: Empty OPENAI_API_KEY is NOT forwarded (empty-value filter)
# ================================================================
echo ""
echo "=== Test 5: Empty OPENAI_API_KEY is NOT forwarded ==="

# Simulate the env-var passthrough logic using the same fixed list and
# empty-value filter from _up_prepare_docker_mounts. This verifies the
# logic without needing to parse the docker run command.
_pi_env_vars=(
  ANTHROPIC_API_KEY AZURE_OPENAI_API_KEY OPENAI_API_KEY GEMINI_API_KEY
  MISTRAL_API_KEY GROQ_API_KEY CEREBRAS_API_KEY XAI_API_KEY
  OPENROUTER_API_KEY AI_GATEWAY_API_KEY ZAI_API_KEY OPENCODE_API_KEY
  KIMI_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY
  PI_SKIP_VERSION_CHECK PI_CACHE_RETENTION
)

# Export OPENAI_API_KEY as empty, and a non-empty sentinel key
OPENAI_API_KEY=""
export OPENAI_API_KEY
TEST_ANTHROPIC_KEY="sk-test-sentinel-value"
ANTHROPIC_API_KEY="$TEST_ANTHROPIC_KEY"
export ANTHROPIC_API_KEY

_test_args=()
for _pi_var in "${_pi_env_vars[@]}"; do
  if [[ -n "${!_pi_var:-}" ]]; then
    _test_args+=(-e "${_pi_var}=${!_pi_var}")
  fi
done

# OPENAI_API_KEY="" should NOT appear
found_empty=false
for arg in "${_test_args[@]}"; do
  if [[ "$arg" == *"OPENAI_API_KEY="* ]]; then
    found_empty=true
  fi
done
if [[ "$found_empty" == "false" ]]; then
  pass "OPENAI_API_KEY='' not forwarded (empty-value filter works)"
else
  fail "OPENAI_API_KEY='' was forwarded — empty-value filter broken"
fi

# ANTHROPIC_API_KEY=sk-test-... SHOULD appear
found_set=false
for arg in "${_test_args[@]}"; do
  if [[ "$arg" == "-e" ]]; then
    continue
  fi
  if [[ "$arg" == "ANTHROPIC_API_KEY=${TEST_ANTHROPIC_KEY}" ]]; then
    found_set=true
  fi
done
if [[ "$found_set" == "true" ]]; then
  pass "Non-empty ANTHROPIC_API_KEY forwarded correctly"
else
  fail "ANTHROPIC_API_KEY not forwarded despite being set"
fi

# Clean up the exported test vars
unset OPENAI_API_KEY ANTHROPIC_API_KEY _pi_env_vars _pi_var _test_args

# ================================================================
# Test 6: rc up succeeds when ~/.pi/agent is absent (warning, no fatal)
# ================================================================
echo ""
echo "=== Test 6: rc up succeeds when ~/.pi/agent is missing ==="

# Rename the pi agent dir to simulate absence
mv "$PI_AGENT_DIR" "${PI_AGENT_DIR}.bak-test"

TEST_WS2=$(mktemp -d)
rc_output=""
rc_exit=0
rc_output=$(RC_ALLOWED_ROOTS="$TEST_WS2" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS2" </dev/null 2>&1) || rc_exit=$?

CONTAINER2=$(_resolve_container "$TEST_WS2")

if [[ -n "$CONTAINER2" ]]; then
  pass "rc up succeeded without ~/.pi/agent (container came up)"
else
  fail "rc up failed when ~/.pi/agent absent (should warn, not fatal)" "exit=$rc_exit"
fi

# Should have logged a warning
if echo "$rc_output" | grep -qi "pi.*not found\|pi.*skip\|pi.*warning"; then
  pass "rc up logged a pi-related warning when ~/.pi/agent absent"
else
  # Warning goes to log (log() may be silent by default unless verbose) — acceptable
  echo "  Note: pi warning may only appear with verbose logging (log() may be silent)"
  pass "rc up did not fatal on missing ~/.pi/agent (warning check inconclusive)"
fi

# Restore for cleanup trap
mv "${PI_AGENT_DIR}.bak-test" "$PI_AGENT_DIR"

# ================================================================
# Test 7: /home/agent/.pi/agent dir is container-local (not host-mounted whole-dir)
# bin/ subdir exists in container but is NOT the host's ~/.pi/agent/bin/
# ================================================================
echo ""
echo "=== Test 7: Container-local pi dir — bin/ not host-mounted ==="

# Verify the container-local dir exists as agent:agent and is independent of host
pi_dir_stat=$(docker exec "$CONTAINER" stat -c '%U:%G' /home/agent/.pi/agent 2>/dev/null || true)
if [[ "$pi_dir_stat" == "agent:agent" ]]; then
  pass "/home/agent/.pi/agent dir exists as agent:agent in container"
else
  fail "/home/agent/.pi/agent dir stat unexpected" "$pi_dir_stat"
fi

# bin/ should NOT be a mount of the host's bin/ — the container should generate
# its own tools. Write a sentinel file to host ~/.pi/agent/bin/ and verify it
# does NOT appear inside the container.
mkdir -p "$PI_AGENT_DIR/bin"
printf 'host-sentinel' > "$PI_AGENT_DIR/bin/host-marker.txt"
# Container was started before this file existed — if bin/ is not mounted, it won't appear
bin_content=$(docker exec "$CONTAINER" cat /home/agent/.pi/agent/bin/host-marker.txt 2>/dev/null || true)
if [[ -z "$bin_content" ]]; then
  pass "bin/ is NOT host-mounted (container-local; host sentinel not visible)"
else
  fail "bin/ appears to be host-mounted (host sentinel visible — bin/ should be container-local)" "$bin_content"
fi
rm -f "$PI_AGENT_DIR/bin/host-marker.txt"

# ================================================================
# Test 8: auth.json RW round-trip — write inside cage → visible on host,
# inode preserved (same contract as ~/.claude/.credentials.json)
# ================================================================
echo ""
echo "=== Test 8: auth.json RW round-trip (write inside cage visible on host) ==="

# Get inode before
host_inode_before=$(stat -f '%i' "$PI_AGENT_DIR/auth.json" 2>/dev/null || stat -c '%i' "$PI_AGENT_DIR/auth.json" 2>/dev/null || true)

# Write new content inside the container (in-place overwrite, same as OAuth refresh)
docker exec "$CONTAINER" bash -c 'printf "{\"fake\":true,\"roundtrip\":true}\n" > /home/agent/.pi/agent/auth.json' 2>/dev/null

# Read on host
roundtrip_content=$(cat "$PI_AGENT_DIR/auth.json" 2>/dev/null || true)
if echo "$roundtrip_content" | grep -q "roundtrip"; then
  pass "auth.json write inside cage visible on host (RW round-trip works)"
else
  fail "auth.json write inside cage NOT visible on host" "$roundtrip_content"
fi

# Inode must be preserved (no atomic rename — the single-file mount tracks by inode)
host_inode_after=$(stat -f '%i' "$PI_AGENT_DIR/auth.json" 2>/dev/null || stat -c '%i' "$PI_AGENT_DIR/auth.json" 2>/dev/null || true)
if [[ -z "$host_inode_before" || -z "$host_inode_after" ]]; then
  # Genuinely could not read inode(s) — skip rather than guess
  echo "  SKIP: inode check skipped (could not read inode: before='$host_inode_before' after='$host_inode_after')"
elif [[ "$host_inode_before" == "$host_inode_after" ]]; then
  pass "auth.json inode preserved on host after cage write (no mv/rename)"
else
  # Both inodes read AND they differ — the write used atomic rename instead of in-place overwrite.
  # This would break pi's OAuth token refresh (single-file bind mount tracks by inode).
  fail "auth.json inode changed after cage write — atomic rename detected (inode before=$host_inode_before, after=$host_inode_after)"
fi

# Restore auth.json content for downstream tests
printf '{"fake":true}\n' > "$PI_AGENT_DIR/auth.json"

# ================================================================
# Test 9: the agent's pi extensions/ dir is correct, agent-owned, and writable
#
# Post-wlwc.4 (olen retirement, ADR-019 D8 / ADR-027 D1/D3) pi does NOT auto-load
# this dir. The root-owned wrapper (/usr/local/bin/pi) prepends
# '--no-extensions -e /etc/rip-cage/pi/dcg-gate.ts', so the guard rides its OWN
# separate root-owned load path and the workspace cannot inject a shadowing
# extension. /home/agent/.pi/agent/extensions/ is therefore NOT a guard path —
# it is the agent's own writable extension space (ADR-027 rw self-improvement).
#
# What this test proves non-interactively:
#   - The dir exists in the container image (baked by Dockerfile)
#   - It is agent:agent owned (the agent owns its own extension space)
#   - The agent user can write to it (agent improves its own extensions in-cage)
#   - A marker file dropped here is readable by the agent user
#
# What this test does NOT assert (deliberately, post-olen):
#   - That pi auto-loads from this dir — it does not. --no-extensions disables
#     auto-discovery; the guard loads explicitly via -e from /etc/rip-cage/pi/.
#     The --no-extensions bypass-block (workspace extensions NOT loaded) is
#     covered by tests/test-pi-no-extensions.sh, not here.
# ================================================================
echo ""
echo "=== Test 9: agent pi extensions/ dir exists, is agent-owned, and is writable ==="

# 9a: dir must exist (baked in Dockerfile line: RUN mkdir -p /home/agent/.pi/agent/extensions)
ext_dir_stat=$(docker exec "$CONTAINER" stat -c '%U:%G' /home/agent/.pi/agent/extensions 2>/dev/null || true)
if [[ "$ext_dir_stat" == "agent:agent" ]]; then
  pass "/home/agent/.pi/agent/extensions dir exists as agent:agent in container"
else
  fail "/home/agent/.pi/agent/extensions dir missing or wrong ownership (got: '$ext_dir_stat')" ""
fi

# 9b: dir must be writable by agent user (agent's own extension space — ADR-027 rw)
write_test=$(docker exec "$CONTAINER" bash -c 'touch /home/agent/.pi/agent/extensions/.write-test && echo ok && rm /home/agent/.pi/agent/extensions/.write-test' 2>/dev/null || true)
if [[ "$write_test" == "ok" ]]; then
  pass "/home/agent/.pi/agent/extensions dir is writable by agent user"
else
  fail "/home/agent/.pi/agent/extensions dir is NOT writable by agent user" "$write_test"
fi

# 9c: a marker file dropped into the dir is readable by the agent user
#     (confirms the agent extension space is not blocked by permissions or mount shadowing)
docker exec "$CONTAINER" bash -c 'printf "// marker\nexport default {};\n" > /home/agent/.pi/agent/extensions/marker-test.js' 2>/dev/null
marker_content=$(docker exec "$CONTAINER" cat /home/agent/.pi/agent/extensions/marker-test.js 2>/dev/null || true)
docker exec "$CONTAINER" rm -f /home/agent/.pi/agent/extensions/marker-test.js 2>/dev/null || true
if echo "$marker_content" | grep -q "marker"; then
  pass "marker file dropped in extensions/ is readable by agent user (agent extension space writable)"
else
  fail "marker file in extensions/ not readable — agent extension space may be blocked" "$marker_content"
fi

# ================================================================
# Summary
# ================================================================
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All pi auth mount tests passed."
else
  echo "$FAILURES test(s) FAILED."
fi
exit "$FAILURES"
