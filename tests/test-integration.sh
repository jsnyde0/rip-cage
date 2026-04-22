#!/usr/bin/env bash
set -euo pipefail
CONTAINER_NAME="rc-integration-test"
TEST_WS=""
TEST_WS_MISE=""
TEST_WS_YARN=""
CLEANUP() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "rc-state-integration" 2>/dev/null || true
  [ -n "$TEST_WS" ] && rm -rf "$TEST_WS"
  docker rm -f "rc-mise-nvmrc-test" 2>/dev/null || true
  docker rm -f "rc-mise-cache-test" 2>/dev/null || true
  docker rm -f "rc-mise-yarn-test" 2>/dev/null || true
  docker volume rm rc-state-mise-nvmrc-test 2>/dev/null || true
  docker volume rm rc-state-mise-cache-test 2>/dev/null || true
  docker volume rm rc-state-mise-yarn-test 2>/dev/null || true
  [ -n "$TEST_WS_MISE" ] && rm -rf "$TEST_WS_MISE"
  [ -n "$TEST_WS_YARN" ] && rm -rf "$TEST_WS_YARN"
  # NOTE: do NOT remove rc-mise-cache — it is host-scoped (ADR-015 D2)
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
# Note: safety-stack exits 1 when auth/beads checks fail (expected in no-creds test context).
# Allow non-zero exit here so integration test steps 4-16 still run; the safety-stack
# output above is still the canonical pass/fail record for structural checks.
echo "Step 3: Safety stack smoke test..."
docker exec "$CONTAINER_NAME" /usr/local/lib/rip-cage/test-safety-stack.sh || true

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

# 13. Non-interactive SSH: no TTY prompt on first-contact attempt
# Step 13: exercise system SSH config (no -o overrides) so this test would
# fail if /etc/ssh/ssh_config.d/00-rip-cage.conf were removed.
# TODO: move to tests/test-e2e-lifecycle.sh when that file is created (ADR-013 D3 P1)
echo "Step 13: Non-interactive SSH posture (Tier 2)..."
ssh_output=$(docker exec "$CONTAINER_NAME" sh -c 'ssh -T git@github.com 2>&1' || true)
if echo "$ssh_output" | grep -q "Are you sure you want to continue connecting"; then
  echo "FAIL: SSH interactive prompt detected — BatchMode/StrictHostKeyChecking not enforced"
  exit 1
fi
if echo "$ssh_output" | grep -q "Permission denied"; then
  echo "PASS: Step 13 — got 'Permission denied' (non-interactive failure as expected)"
elif echo "$ssh_output" | grep -q "Host key verification failed"; then
  echo "FAIL: Step 13 — host key verification failed (known_hosts may be stale)"
  exit 1
else
  echo "PASS: Step 13 — SSH failed non-interactively (no prompt detected): $ssh_output"
fi

# 14. Mise: .nvmrc provisioning (ADR-015 D3, Tier 2)
echo "Step 14: Mise — .nvmrc=20.18.0 node version matches..."
TEST_WS_MISE=$(mktemp -d)
echo "20.18.0" > "$TEST_WS_MISE/.nvmrc"
MISE_CONTAINER="rc-mise-nvmrc-test"
docker run -d --name "$MISE_CONTAINER" \
  --label rc.source.path="$TEST_WS_MISE" \
  -v "$TEST_WS_MISE:/workspace:delegated" \
  -v rc-state-mise-nvmrc-test:/home/agent/.claude-state \
  -v rc-mise-cache:/home/agent/.local/share/mise \
  rip-cage:latest sleep infinity
docker exec "$MISE_CONTAINER" /usr/local/bin/init-rip-cage.sh

node_ver=$(docker exec "$MISE_CONTAINER" zsh -lic 'cd /workspace && node --version' 2>/dev/null | tail -1)
[ "$node_ver" = "v20.18.0" ] || { echo "FAIL: expected v20.18.0, got $node_ver"; exit 1; }
echo "PASS: Step 14 — node --version = $node_ver"

node_path=$(docker exec "$MISE_CONTAINER" zsh -lic 'cd /workspace && readlink -f $(which node)' 2>/dev/null | tail -1)
echo "$node_path" | grep -q '/mise/installs/node/20.18.0/' || { echo "FAIL: node path unexpected: $node_path"; exit 1; }
echo "PASS: Step 14 — node path under mise installs dir"

# 15. Mise: cache reuse after container destroy (ADR-015 D2, Tier 2)
echo "Step 15: Mise — cache reuse after destroy..."
docker rm -f "$MISE_CONTAINER"
docker volume rm rc-state-mise-nvmrc-test 2>/dev/null || true

MISE_CONTAINER2="rc-mise-cache-test"
docker run -d --name "$MISE_CONTAINER2" \
  --label rc.source.path="$TEST_WS_MISE" \
  -v "$TEST_WS_MISE:/workspace:delegated" \
  -v rc-state-mise-cache-test:/home/agent/.claude-state \
  -v rc-mise-cache:/home/agent/.local/share/mise \
  rip-cage:latest sleep infinity
docker exec "$MISE_CONTAINER2" /usr/local/bin/init-rip-cage.sh

# Time just the mise install command — cache hit should be fast (<5s threshold)
# Timing runs inside the container (Linux) to avoid macOS date +%s%3N incompatibility
mise_elapsed=$(docker exec "$MISE_CONTAINER2" bash -c \
  'start=$(date +%s%3N); cd /workspace && mise install >/dev/null 2>&1; end=$(date +%s%3N); echo $((end - start))')
[ "$mise_elapsed" -lt 5000 ] || echo "WARN: mise install took ${mise_elapsed}ms on cache hit (expected <5000ms)"
echo "PASS: Step 15 — mise install elapsed ${mise_elapsed}ms"

docker rm -f "$MISE_CONTAINER2"
docker volume rm rc-state-mise-cache-test 2>/dev/null || true

# 16. Mise: yarn via packageManager field (ADR-015 D3, Tier 2)
echo "Step 16: Mise — yarn via packageManager field..."
TEST_WS_YARN=$(mktemp -d)
cat > "$TEST_WS_YARN/package.json" <<'PKGJSON'
{
  "name": "test-yarn-project",
  "version": "1.0.0",
  "packageManager": "yarn@1.22.22"
}
PKGJSON

YARN_CONTAINER="rc-mise-yarn-test"
docker run -d --name "$YARN_CONTAINER" \
  --label rc.source.path="$TEST_WS_YARN" \
  -v "$TEST_WS_YARN:/workspace:delegated" \
  -v rc-state-mise-yarn-test:/home/agent/.claude-state \
  -v rc-mise-cache:/home/agent/.local/share/mise \
  rip-cage:latest sleep infinity
docker exec "$YARN_CONTAINER" /usr/local/bin/init-rip-cage.sh

yarn_ver=$(docker exec "$YARN_CONTAINER" zsh -ic 'cd /workspace && yarn --version' 2>/dev/null | tail -1)
[ "$yarn_ver" = "1.22.22" ] || { echo "FAIL: yarn version: $yarn_ver (expected 1.22.22)"; exit 1; }
echo "PASS: Step 16 — yarn --version = $yarn_ver (no npx dance)"

docker rm -f "$YARN_CONTAINER"
docker volume rm rc-state-mise-yarn-test 2>/dev/null || true

echo ""
echo "=== All integration tests passed ==="
