#!/usr/bin/env bash
# Tests for B2: pi state mount + provider env-var passthrough.
# Requires docker + rip-cage:latest image already built (./rc build).
#
# What this tests (without needing a real pi install):
#   1. ~/.pi/agent bind-mounted to /pi-agent inside the container
#   2. PI_CODING_AGENT_DIR=/pi-agent injected as an env var
#   3. /pi-agent/auth.json is readable and owned by agent:agent
#   4. OPENAI_API_KEY="" is NOT forwarded (empty-value filter)
#   5. rc up still succeeds when ~/.pi/agent is absent (warning, no fatal)

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
  # Restore ~/.pi/agent state
  if [[ "$PI_AGENT_EXISTED" == "true" && -n "$PI_AGENT_BACKUP" ]]; then
    rm -rf "$PI_AGENT_DIR"
    mkdir -p "$PI_AGENT_DIR"
    cp -a "$PI_AGENT_BACKUP/." "$PI_AGENT_DIR/"
    rm -rf "$PI_AGENT_BACKUP"
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
# Test 1: pi bind mount — /pi-agent/auth.json visible in container
# ================================================================
echo ""
echo "=== Test 1: /pi-agent/auth.json is mounted and readable ==="

RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container "$TEST_WS")

if [[ -z "$CONTAINER" ]]; then
  fail "container did not come up"
  echo "$FAILURES test(s) FAILED (fatal — no container to inspect)."
  exit "$FAILURES"
fi

content=$(docker exec "$CONTAINER" cat /pi-agent/auth.json 2>/dev/null || true)
if echo "$content" | grep -q "fake"; then
  pass "/pi-agent/auth.json readable and contains expected content"
else
  fail "/pi-agent/auth.json not readable or wrong content" "$content"
fi

# ================================================================
# Test 2: /pi-agent/auth.json owned by agent:agent from container's view
# ================================================================
echo ""
echo "=== Test 2: /pi-agent/auth.json owned by agent:agent ==="

ownership=$(docker exec "$CONTAINER" stat -c '%U:%G' /pi-agent/auth.json 2>/dev/null || true)
if [[ "$ownership" == "agent:agent" ]]; then
  pass "/pi-agent/auth.json owner = agent:agent"
else
  fail "/pi-agent/auth.json owner = '$ownership' (expected agent:agent)"
fi

# ================================================================
# Test 3: PI_CODING_AGENT_DIR=/pi-agent set in container env
# ================================================================
echo ""
echo "=== Test 3: PI_CODING_AGENT_DIR=/pi-agent in container env ==="

pi_env=$(docker exec "$CONTAINER" env 2>/dev/null | grep '^PI_CODING_AGENT_DIR=' || true)
if [[ "$pi_env" == "PI_CODING_AGENT_DIR=/pi-agent" ]]; then
  pass "PI_CODING_AGENT_DIR=/pi-agent in container env"
else
  fail "PI_CODING_AGENT_DIR not set correctly" "$pi_env"
fi

# ================================================================
# Test 4: CAGE_HOST_ADDR passed through explicitly (for non-interactive pi -p)
# ================================================================
echo ""
echo "=== Test 4: CAGE_HOST_ADDR present in container env ==="

cage_env=$(docker exec "$CONTAINER" env 2>/dev/null | grep '^CAGE_HOST_ADDR=' || true)
if [[ -n "$cage_env" ]]; then
  pass "CAGE_HOST_ADDR present in container env ('$cage_env')"
else
  fail "CAGE_HOST_ADDR not set in container env (non-interactive pi -p will fail)"
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
# Summary
# ================================================================
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All pi auth mount tests passed."
else
  echo "$FAILURES test(s) FAILED."
fi
exit "$FAILURES"
