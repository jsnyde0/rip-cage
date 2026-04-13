#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="$SCRIPT_DIR/rc"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Create isolated temp directories
ALLOWED_DIR=$(mktemp -d)
OUTSIDE_DIR=$(mktemp -d)
PROJECT_DIR="$ALLOWED_DIR/myproject"
mkdir -p "$PROJECT_DIR"
echo "test" > "$PROJECT_DIR/README.md"

# Create a real env file outside allowed roots
echo "FOO=bar" > "$OUTSIDE_DIR/secrets.env"

# Create a symlink inside allowed roots pointing to the outside file
ln -s "$OUTSIDE_DIR/secrets.env" "$PROJECT_DIR/.env"

cleanup() {
  rm -rf "$ALLOWED_DIR" "$OUTSIDE_DIR"
}
trap cleanup EXIT

export RC_ALLOWED_ROOTS="$ALLOWED_DIR"

echo "=== Security Hardening Tests ==="
echo ""

# --- Test 1: Symlink env-file pointing outside allowed roots is rejected ---
echo "-- Test 1: env-file symlink bypass is blocked --"
# The symlink $PROJECT_DIR/.env resolves to $OUTSIDE_DIR/secrets.env
# which is outside RC_ALLOWED_ROOTS. This MUST be rejected.
OUTPUT=$("$RC" --dry-run up "$PROJECT_DIR" --env-file "$PROJECT_DIR/.env" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

if [[ "$EXIT_CODE" -ne 0 ]]; then
  pass "env-file symlink outside allowed roots rejected (exit $EXIT_CODE)"
else
  fail "env-file symlink outside allowed roots was NOT rejected (exit 0)"
  echo "  Output: $OUTPUT"
fi

# --- Test 2: Legitimate env-file inside allowed roots is accepted ---
echo ""
echo "-- Test 2: env-file inside allowed roots is accepted --"
echo "BAR=baz" > "$PROJECT_DIR/legit.env"
OUTPUT=$("$RC" --dry-run up "$PROJECT_DIR" --env-file "$PROJECT_DIR/legit.env" 2>&1) || EXIT_CODE2=$?
EXIT_CODE2=${EXIT_CODE2:-0}

if [[ "$EXIT_CODE2" -eq 0 ]]; then
  pass "legitimate env-file accepted"
else
  fail "legitimate env-file rejected (exit $EXIT_CODE2)"
  echo "  Output: $OUTPUT"
fi

# --- Test 3: Non-existent env-file is rejected ---
echo ""
echo "-- Test 3: non-existent env-file is rejected --"
OUTPUT=$("$RC" --dry-run up "$PROJECT_DIR" --env-file "$PROJECT_DIR/nonexistent.env" 2>&1) || EXIT_CODE3=$?
EXIT_CODE3=${EXIT_CODE3:-0}

if [[ "$EXIT_CODE3" -ne 0 ]]; then
  pass "non-existent env-file rejected"
else
  fail "non-existent env-file was NOT rejected"
fi

# --- Test 4: Dockerfile sudoers does NOT contain unrestricted chown ---
echo ""
echo "-- Test 4: Dockerfile sudoers pins chown to exact paths --"
SUDOERS_LINE=$(grep 'sudoers.d/agent' "$SCRIPT_DIR/Dockerfile")
if echo "$SUDOERS_LINE" | grep -q '/usr/bin/chown \*'; then
  fail "sudoers still contains unrestricted /usr/bin/chown *"
elif echo "$SUDOERS_LINE" | grep -q '/usr/bin/chown agent'; then
  pass "sudoers pins chown to exact paths (static check)"
else
  fail "sudoers does not contain any chown entry"
fi
if echo "$SUDOERS_LINE" | grep -q 'npm install'; then
  fail "sudoers still contains npm install"
fi

# --- Test 5: Runtime sudoers verification (requires running container) ---
echo ""
echo "-- Test 5: runtime sudoers denies unsafe chown (skip if no container) --"
CONTAINER=$(docker ps --filter label=rc.source.path --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$CONTAINER" ]]; then
  echo "  SKIP: no running rip-cage container"
else
  # Verify the container is properly initialized (has sudo)
  if ! docker exec "$CONTAINER" which sudo >/dev/null 2>&1; then
    echo "  SKIP: container $CONTAINER not fully initialized (no sudo)"
  else
    CONTAINER_IMAGE=$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null)
    LATEST_IMAGE=$(docker image inspect rip-cage:latest --format '{{.Id}}' 2>/dev/null)
    echo "  Testing against container: $CONTAINER"
    if [[ -n "$LATEST_IMAGE" ]] && [[ "$CONTAINER_IMAGE" != "$LATEST_IMAGE" ]]; then
      echo "  SKIP: container uses stale image (rebuild with: rc destroy && rc up)"
    else
      # Should be denied: chown on safety-stack binary
      if docker exec "$CONTAINER" sudo chown agent:agent /usr/local/bin/dcg 2>&1 | grep -qi 'not allowed\|sorry\|permission'; then
        pass "runtime: sudo chown on /usr/local/bin/dcg denied"
      else
        fail "runtime: sudo chown on /usr/local/bin/dcg was NOT denied"
      fi
      # Should succeed: chown on allowed path
      if docker exec "$CONTAINER" sudo chown agent:agent /home/agent/.claude 2>/dev/null; then
        pass "runtime: sudo chown on /home/agent/.claude allowed"
      else
        fail "runtime: sudo chown on /home/agent/.claude denied"
      fi
    fi
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
