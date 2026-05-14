#!/usr/bin/env bash
set -uo pipefail

# rip-cage-6n4.1 — verify rc up's auto-build branch pulls from GHCR before
# falling back to docker build, and honors RIP_CAGE_IMAGE_REGISTRY="" as
# explicit opt-out. ADR-008 D6.
#
# Strategy: use --dry-run with a fake docker on PATH that reports "image
# missing" via `docker image inspect`. The dry-run JSON tells us which branch
# would fire (would_pull vs would_build) without actually pulling/building.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Fake docker sandbox. Reports "image missing" so the auto-provisioning branch
# fires. Returns success for `info` so rc's preflight passes.
FAKE_BIN=$(mktemp -d)
cleanup() { rm -rf "$FAKE_BIN"; }
trap cleanup EXIT

cat > "$FAKE_BIN/docker" <<'FAKEEOF'
#!/usr/bin/env bash
case "${1:-}" in
  info)
    echo "Server Version: fake"
    exit 0
    ;;
  image)
    if [[ "${2:-}" == "inspect" ]]; then
      # Image missing — trigger the auto-provisioning branch.
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKEEOF
chmod +x "$FAKE_BIN/docker"

# Need a real path inside an allowed root for rc up to accept. Use a temp dir
# under $HOME (the default allowed root in test contexts).
TARGET=$(mktemp -d -t "rc-pull-test.XXXXXX")
cleanup_target() { rm -rf "$TARGET"; }
trap 'cleanup; cleanup_target' EXIT

# -----------------------------------------------------------------------------
# Test 1: default RIP_CAGE_IMAGE_REGISTRY → dry-run says "would_pull"
# -----------------------------------------------------------------------------
echo ""
echo "=== Test 1: --dry-run with default registry → would_pull ==="
output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$(dirname "$TARGET")" \
  "$RC" --output json --dry-run up "$TARGET" 2>&1 || true)

if echo "$output" | grep -q '"would_pull":true'; then
  pass "default registry: would_pull is true"
else
  fail "default registry: expected would_pull:true" "$output"
fi
if echo "$output" | grep -q '"would_build_on_fail":true'; then
  pass "default registry: would_build_on_fail is true (fallback documented)"
else
  fail "default registry: expected would_build_on_fail:true" "$output"
fi
if echo "$output" | grep -q 'ghcr.io/jsnyde0/rip-cage'; then
  pass "default registry: pull ref names ghcr.io/jsnyde0/rip-cage"
else
  fail "default registry: expected ghcr.io/jsnyde0/rip-cage in image field" "$output"
fi

# -----------------------------------------------------------------------------
# Test 2: RIP_CAGE_IMAGE_REGISTRY="" → dry-run says "would_build"
# -----------------------------------------------------------------------------
echo ""
echo "=== Test 2: --dry-run with RIP_CAGE_IMAGE_REGISTRY='' → would_build ==="
output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$(dirname "$TARGET")" \
  RIP_CAGE_IMAGE_REGISTRY="" \
  "$RC" --output json --dry-run up "$TARGET" 2>&1 || true)

if echo "$output" | grep -q '"would_build":true'; then
  pass "empty registry: would_build is true (opt-out honored)"
else
  fail "empty registry: expected would_build:true" "$output"
fi
if echo "$output" | grep -q '"would_pull"'; then
  fail "empty registry: should NOT mention would_pull" "$output"
else
  pass "empty registry: dry-run does not mention would_pull"
fi

# -----------------------------------------------------------------------------
# Test 3: human-mode dry-run with default registry mentions "pull"
# -----------------------------------------------------------------------------
echo ""
echo "=== Test 3: --dry-run human-mode with default registry ==="
output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$(dirname "$TARGET")" \
  "$RC" --dry-run up "$TARGET" 2>&1 || true)

if echo "$output" | grep -qi "would pull"; then
  pass "human dry-run: names the pull"
else
  fail "human dry-run: expected 'would pull' in output" "$output"
fi
if echo "$output" | grep -qi "local-build fallback"; then
  pass "human dry-run: names the local-build fallback"
else
  fail "human dry-run: expected 'local-build fallback' in output" "$output"
fi

# -----------------------------------------------------------------------------
# Test 4: human-mode dry-run with empty registry mentions "build" only
# -----------------------------------------------------------------------------
echo ""
echo "=== Test 4: --dry-run human-mode with empty registry ==="
output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$(dirname "$TARGET")" \
  RIP_CAGE_IMAGE_REGISTRY="" \
  "$RC" --dry-run up "$TARGET" 2>&1 || true)

if echo "$output" | grep -qi "would build"; then
  pass "human dry-run, opt-out: names the build"
else
  fail "human dry-run, opt-out: expected 'would build' in output" "$output"
fi
if echo "$output" | grep -qi "would pull"; then
  fail "human dry-run, opt-out: should NOT mention 'would pull'" "$output"
else
  pass "human dry-run, opt-out: does not mention pull"
fi

# -----------------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------------
echo ""
if (( FAILURES > 0 )); then
  echo "=== test-pull-first.sh: ${FAILURES} failure(s) ==="
  exit 1
fi
echo "=== test-pull-first.sh: all tests passed ==="
