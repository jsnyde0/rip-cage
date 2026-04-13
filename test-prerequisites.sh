#!/usr/bin/env bash
set -uo pipefail

# Test prerequisite checks in rc
# Uses PATH manipulation to simulate missing tools

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Create temp dirs for fake binaries
FAKE_BIN=$(mktemp -d)
SYMLINK_BIN=$(mktemp -d)  # symlink farm for PATH without jq
cleanup() {
  rm -rf "$FAKE_BIN" "$SYMLINK_BIN"
}
trap cleanup EXIT

# Fake docker that reports daemon not running
cat > "$FAKE_BIN/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  echo "Error response from daemon: Is the docker daemon running?" >&2
  exit 1
fi
exit 0
DOCKEREOF
chmod +x "$FAKE_BIN/docker"

# Build a PATH that has no jq at all.
# Strategy: symlink every executable from the real PATH dirs into SYMLINK_BIN, skipping jq.
# This gives us a single-dir PATH that has all needed tools (bash, dirname, etc.) minus jq.
_build_nojq_path() {
  local target_dir="$1"
  local skip_tool="$2"
  # Walk each dir in PATH
  local IFS=':'
  for dir in $PATH; do
    [[ -d "$dir" ]] || continue
    for bin in "$dir"/*; do
      local name
      name="$(basename "$bin")"
      [[ "$name" == "$skip_tool" ]] && continue  # skip the tool we want absent
      [[ -x "$bin" ]] || continue
      # Only link if not already present (first-in-PATH wins)
      [[ -e "$target_dir/$name" ]] || ln -sf "$bin" "$target_dir/$name"
    done
  done
  echo "$target_dir"
}

NOJQ_BIN=$(_build_nojq_path "$SYMLINK_BIN" "jq")
# tmux is not installed on this host — regular PATH works for tmux tests

# -----------------------------------------------
# Test 1: Missing jq — rc ls --output json fails with helpful message
# -----------------------------------------------
echo ""
echo "=== Test 1: Missing jq gives helpful error for --output json ==="

# Use the symlink-farm PATH that has everything except jq
output=$(RC_ALLOWED_ROOTS="$HOME" PATH="$NOJQ_BIN" "$RC" ls --output json 2>&1 || true)
if echo "$output" | grep -qi "jq"; then
  pass "missing jq: error mentions 'jq'"
else
  fail "missing jq: error should mention 'jq'" "$output"
fi
if echo "$output" | grep -qi "install"; then
  pass "missing jq: error mentions 'install'"
else
  fail "missing jq: error should give install instructions" "$output"
fi

# -----------------------------------------------
# Test 2: Missing tmux — rc up fails with helpful message
# -----------------------------------------------
echo ""
echo "=== Test 2: Missing tmux gives helpful error for rc up ==="

# tmux is not installed on this host, so regular PATH is sufficient
output=$(RC_ALLOWED_ROOTS="$HOME" "$RC" up . 2>&1 || true)
if echo "$output" | grep -qi "tmux"; then
  pass "missing tmux: error mentions 'tmux'"
else
  fail "missing tmux: error should mention 'tmux'" "$output"
fi
if echo "$output" | grep -qi "install"; then
  pass "missing tmux: error mentions 'install'"
else
  fail "missing tmux: error should give install instructions" "$output"
fi

# -----------------------------------------------
# Test 3: Docker daemon not running — rc ls fails with helpful message
# -----------------------------------------------
echo ""
echo "=== Test 3: Docker daemon not running gives helpful error ==="

output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" ls 2>&1 || true)
if echo "$output" | grep -qi "docker"; then
  pass "docker not running: error mentions 'docker'"
else
  fail "docker not running: error should mention 'docker'" "$output"
fi
if echo "$output" | grep -qi "running\|daemon\|start"; then
  pass "docker not running: error mentions daemon/running/start"
else
  fail "docker not running: error should mention daemon status" "$output"
fi

# -----------------------------------------------
# Test 4: Commands that need docker check it (build, up, ls, attach, down, destroy, test)
# -----------------------------------------------
echo ""
echo "=== Test 4: Docker check runs for docker-dependent commands ==="

for cmd in build ls; do
  output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" $cmd 2>&1 || true)
  if echo "$output" | grep -qi "docker"; then
    pass "docker check for 'rc $cmd'"
  else
    fail "docker check for 'rc $cmd'" "$output"
  fi
done

# -----------------------------------------------
# Test 5: rc schema (no docker needed) does NOT trigger docker check
# -----------------------------------------------
echo ""
echo "=== Test 5: rc schema does not require docker ==="

output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" schema 2>&1 || true)
if echo "$output" | grep -q '"version"'; then
  pass "rc schema works without docker daemon"
else
  fail "rc schema should work without docker daemon" "$output"
fi

# -----------------------------------------------
# Test 6: rc init does NOT require tmux
# -----------------------------------------------
echo ""
echo "=== Test 6: rc init does not require tmux ==="

TEST_DIR=$(mktemp -d)
# tmux is not installed on this host — regular PATH is sufficient to test that rc init still works
output=$(RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR")" "$RC" init "$TEST_DIR" 2>&1 || true)
if [[ -f "$TEST_DIR/.devcontainer/devcontainer.json" ]]; then
  pass "rc init works without tmux"
else
  fail "rc init should work without tmux" "$output"
fi
rm -rf "$TEST_DIR"

# -----------------------------------------------
# Summary
# -----------------------------------------------
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All prerequisite tests passed."
else
  echo "$FAILURES test(s) FAILED."
  exit 1
fi
