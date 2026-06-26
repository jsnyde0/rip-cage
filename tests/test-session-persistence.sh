#!/usr/bin/env bash
# Test: Claude Code session JSONL logs persist to host (rip-cage-dn2)
#
# Validates the CLI (rc up) path for session persistence:
#   1. `rc --dry-run up` advertises the projects/sessions bind-mounts + RC_HOST_PROJECT_KEY
#      for the CLI path.
#   2. End-to-end: a file written inside the container at
#      ~/.claude/projects/-workspace/ lands on the host under
#      ~/.claude/projects/<encoded-host-path>/ and survives `rc destroy`.
#
# The host-key encoding matches Claude Code's convention: tr '/.' '-'.
#
# Note: Phase 1 (rc init devcontainer.json) was removed in rip-cage-kt25.
# The VS Code devcontainer path is no longer supported.
#
# Runtime: <5s for phase 1 (dry-run); ~30-60s for phase 2 (warm image).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

PASS=0; FAIL=0; TOTAL=0
check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ -- $detail}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  [$TOTAL] $name${detail:+ -- $detail}"
    FAIL=$((FAIL + 1))
  fi
}

# Per-phase tmp dirs so cleanup is straightforward
DRY_TMP=""
E2E_TMP=""
CONTAINER_NAME=""
HOST_PROJECTS_DIR=""

CLEANUP() {
  [[ -n "$CONTAINER_NAME" ]] && docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  [[ -n "$CONTAINER_NAME" ]] && docker volume rm "rc-state-${CONTAINER_NAME}" >/dev/null 2>&1 || true
  [[ -n "$HOST_PROJECTS_DIR" && "$HOST_PROJECTS_DIR" == "$HOME/.claude/projects/"*"-rc-dn2-test"* ]] && rm -rf "$HOST_PROJECTS_DIR"
  [[ -n "$DRY_TMP"  ]] && rm -rf "$DRY_TMP"
  [[ -n "$E2E_TMP"  ]] && rm -rf "$E2E_TMP"
}
trap CLEANUP EXIT

echo "=== Phase 1: rc up --dry-run ==="
DRY_TMP=$(mktemp -d)
DRY_PROJECT="$DRY_TMP/dryrun-fixture"
mkdir -p "$DRY_PROJECT"
DRY_PARENT_RESOLVED=$(cd "$DRY_TMP" && pwd -P)
DRY_OUT=$(RC_ALLOWED_ROOTS="$DRY_PARENT_RESOLVED" "$RC" --dry-run up "$DRY_PROJECT" 2>&1 || true)
DRY_PROJECT_RESOLVED=$(cd "$DRY_PROJECT" && pwd -P)
EXPECTED_DRY_KEY=$(printf '%s' "$DRY_PROJECT_RESOLVED" | tr '/.' '-')

if echo "$DRY_OUT" | grep -q "~/.claude/projects -> /home/agent/.claude/projects"; then
  check "dry-run advertises projects bind-mount" pass
else
  check "dry-run advertises projects bind-mount" fail
fi
if echo "$DRY_OUT" | grep -q "~/.claude/sessions -> /home/agent/.claude/sessions"; then
  check "dry-run advertises sessions bind-mount" pass
else
  check "dry-run advertises sessions bind-mount" fail
fi
if echo "$DRY_OUT" | grep -q "RC_HOST_PROJECT_KEY=$EXPECTED_DRY_KEY"; then
  check "dry-run sets RC_HOST_PROJECT_KEY=$EXPECTED_DRY_KEY" pass
else
  check "dry-run sets RC_HOST_PROJECT_KEY" fail "(actual output below)\n$DRY_OUT"
fi

echo ""
echo "=== Phase 2: E2E lifecycle ==="
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: Docker not available"
  echo ""
  echo "$PASS/$TOTAL passed, $FAIL failed"
  exit $FAIL
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not present (run ./rc build)"
  echo ""
  echo "$PASS/$TOTAL passed, $FAIL failed"
  exit $FAIL
fi

# container_name() derives from parent + basename. Stage as <tmp>/rc/dn2-test
# so we get the deterministic name "rc-dn2-test".
E2E_TMP=$(mktemp -d)
mkdir -p "$E2E_TMP/rc"
E2E_PROJECT="$E2E_TMP/rc/dn2-test"
mkdir -p "$E2E_PROJECT"
CONTAINER_NAME="rc-dn2-test"
E2E_RESOLVED=$(cd "$E2E_TMP" && pwd -P)
E2E_PROJECT_RESOLVED=$(cd "$E2E_PROJECT" && pwd -P)
HOST_KEY=$(printf '%s' "$E2E_PROJECT_RESOLVED" | tr '/.' '-')
HOST_PROJECTS_DIR="$HOME/.claude/projects/$HOST_KEY"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume rm "rc-state-${CONTAINER_NAME}" >/dev/null 2>&1 || true
rm -rf "$HOST_PROJECTS_DIR"

UP_OUT=$(mktemp)
RC_ALLOWED_ROOTS="$E2E_RESOLVED" "$RC" up "$E2E_PROJECT" </dev/null >"$UP_OUT" 2>&1 || true

if docker ps --filter "name=^${CONTAINER_NAME}\$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  check "rc up brings container up" pass
else
  check "rc up brings container up" fail "(see $UP_OUT)"
  cat "$UP_OUT"
  echo ""
  echo "$PASS/$TOTAL passed, $FAIL failed"
  exit 1
fi

# Bind-mount check via /proc/mounts (mountpoint(1) not guaranteed inside image)
if docker exec "$CONTAINER_NAME" awk '$2 == "/home/agent/.claude/projects" { found=1; exit } END { exit !found }' /proc/mounts; then
  check "~/.claude/projects is a mountpoint inside container" pass
else
  check "~/.claude/projects is a mountpoint inside container" fail
fi
if docker exec "$CONTAINER_NAME" awk '$2 == "/home/agent/.claude/sessions" { found=1; exit } END { exit !found }' /proc/mounts; then
  check "~/.claude/sessions is a mountpoint inside container" pass
else
  check "~/.claude/sessions is a mountpoint inside container" fail
fi

# Symlink target check
LINK_TARGET=$(docker exec "$CONTAINER_NAME" readlink /home/agent/.claude/projects/-workspace 2>/dev/null || true)
if [[ "$LINK_TARGET" == "$HOST_KEY" ]]; then
  check "-workspace symlink resolves to host project key" pass "$HOST_KEY"
else
  check "-workspace symlink resolves to host project key" fail "got '$LINK_TARGET' expected '$HOST_KEY'"
fi

# RC_HOST_PROJECT_KEY env propagated
ENV_KEY=$(docker exec "$CONTAINER_NAME" printenv RC_HOST_PROJECT_KEY 2>/dev/null || true)
if [[ "$ENV_KEY" == "$HOST_KEY" ]]; then
  check "RC_HOST_PROJECT_KEY env set in container" pass
else
  check "RC_HOST_PROJECT_KEY env set in container" fail "got '$ENV_KEY'"
fi

# Write a session-like file from inside the container, via the -workspace symlink.
# This simulates Claude Code writing a session keyed by the container's cwd (/workspace).
docker exec "$CONTAINER_NAME" sh -c \
  'echo "{\"type\":\"test\",\"msg\":\"rip-cage-dn2 persistence\"}" \
     > /home/agent/.claude/projects/-workspace/dn2-probe.jsonl' \
  >/dev/null 2>&1 \
  && check "write inside container via -workspace symlink" pass \
  || check "write inside container via -workspace symlink" fail

if [[ -f "$HOST_PROJECTS_DIR/dn2-probe.jsonl" ]]; then
  check "host sees session file at unified project key path" pass
else
  check "host sees session file at unified project key path" fail "missing $HOST_PROJECTS_DIR/dn2-probe.jsonl"
fi

# Now destroy and verify file survives
"$RC" destroy -f "$CONTAINER_NAME" >/dev/null 2>&1 || \
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1

if docker ps -a --filter "name=^${CONTAINER_NAME}\$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  check "rc destroy removes container" fail
else
  check "rc destroy removes container" pass
fi
if [[ -f "$HOST_PROJECTS_DIR/dn2-probe.jsonl" ]]; then
  check "session file survives rc destroy" pass
else
  check "session file survives rc destroy" fail "lost $HOST_PROJECTS_DIR/dn2-probe.jsonl"
fi

# Don't reset CONTAINER_NAME — the trap cleanup uses it (idempotent rm -f).
rm -f "$UP_OUT"

echo ""
echo "$PASS/$TOTAL passed, $FAIL failed"
exit $FAIL
