#!/usr/bin/env bash
set -euo pipefail
CONTAINER_NAME="rc-integration-test"
TEST_WS=""
CLEANUP() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "rc-state-integration" 2>/dev/null || true
  [ -n "$TEST_WS" ] && rm -rf "$TEST_WS"
}
trap CLEANUP EXIT

echo "=== Rip Cage Integration Test ==="

# 0. Prerequisites
echo "Step 0: Check prerequisites..."
docker info > /dev/null 2>&1 || { echo "FAIL: Docker not running"; exit 1; }
docker image inspect rip-cage:latest > /dev/null 2>&1 || {
  echo "Building image..."
  docker buildx build -t rip-cage:latest ~/.claude/rip-cage/
}

# 1. Create test workspace
TEST_WS=$(mktemp -d)
mkdir -p "$TEST_WS/.beads"
echo "Test workspace: $TEST_WS"

# 2. Start container (non-interactive, override CMD with sleep infinity)
echo "Step 2: Starting container..."
docker run -d --name "$CONTAINER_NAME" \
  --label rc.source.path="$TEST_WS" \
  -v "$TEST_WS:/workspace:delegated" \
  -v rc-state-integration:/home/agent/.claude-state \
  rip-cage:latest sleep infinity
docker exec "$CONTAINER_NAME" /usr/local/bin/init-rip-cage.sh

# 3. Run safety stack smoke test
echo "Step 3: Safety stack smoke test..."
docker exec "$CONTAINER_NAME" /usr/local/lib/rip-cage/test-safety-stack.sh

# 4. Verify settings.json in place
echo "Step 4: Verify settings.json..."
docker exec "$CONTAINER_NAME" test -f /home/agent/.claude/settings.json

# 5. Verify non-root user
echo "Step 5: Verify non-root user..."
USER=$(docker exec "$CONTAINER_NAME" whoami)
[ "$USER" = "agent" ] || { echo "FAIL: user is $USER, expected agent"; exit 1; }

# 6. Verify /workspace mount (bidirectional)
echo "Step 6: Verify workspace mount..."
docker exec "$CONTAINER_NAME" touch /workspace/test-file
[ -f "$TEST_WS/test-file" ] || { echo "FAIL: workspace mount not working"; exit 1; }

# 7. Verify all tools accessible by agent user
echo "Step 7: Verify tools..."
for tool in claude dcg bd uv bun node gh git perl jq tmux zsh; do
  docker exec "$CONTAINER_NAME" which "$tool" > /dev/null 2>&1 || { echo "FAIL: $tool not found"; exit 1; }
done

# 8. Verify CLAUDE.md skip behavior (no CLAUDE.md mounted)
echo "Step 8: Verify no CLAUDE.md leaked into container..."
docker exec "$CONTAINER_NAME" test ! -f /home/agent/.claude/CLAUDE.md || { echo "FAIL: CLAUDE.md should not exist (no mount provided)"; exit 1; }

# 9. Verify hook paths in settings.json match actual files
echo "Step 9: Verify hook path consistency..."
docker exec "$CONTAINER_NAME" test -x /usr/local/bin/dcg
docker exec "$CONTAINER_NAME" test -x /usr/local/lib/rip-cage/hooks/block-compound-commands.sh

# 10. Verify persistent state symlinks (from init step 3)
echo "Step 10: Verify persistent state..."
docker exec "$CONTAINER_NAME" test -L /home/agent/.claude/projects || { echo "FAIL: projects symlink missing"; exit 1; }
docker exec "$CONTAINER_NAME" test -L /home/agent/.claude/sessions || { echo "FAIL: sessions symlink missing"; exit 1; }

# 11. bd wrapper is a shell script (shebang check — file command not available in container)
echo "Step 11: Verify bd wrapper is a shell script..."
BD_SHEBANG=$(docker exec "$CONTAINER_NAME" sh -c 'head -c 2 /usr/local/bin/bd')
[ "$BD_SHEBANG" = "#!" ] || { echo "FAIL: bd is not a shell script (shebang='$BD_SHEBANG')"; exit 1; }

# 12. bd-real exists and is executable
echo "Step 12: Verify bd-real exists and is executable..."
docker exec "$CONTAINER_NAME" test -x /usr/local/bin/bd-real || { echo "FAIL: bd-real not executable or missing"; exit 1; }

echo ""
echo "=== All integration tests passed ==="
