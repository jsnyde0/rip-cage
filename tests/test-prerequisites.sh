#!/usr/bin/env bash
set -uo pipefail

# Test prerequisite checks in rc
# Uses PATH manipulation to simulate missing tools

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

# Create temp dirs for fake binaries
FAKE_BIN=$(mktemp -d)
SYMLINK_BIN=$(mktemp -d)   # symlink farm for PATH without jq
T2_WKSP=""                 # initialized here so cleanup() can safely remove it
cleanup() {
  rm -rf "$FAKE_BIN" "$SYMLINK_BIN"
  [[ -n "$T2_WKSP" ]] && rm -rf "$T2_WKSP"
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
# Test 2: session.multiplexer=tmux without manifest declaration fails loud.
# rip-cage-61al.4: tmux is now manifest/registry-derived, not a static enum.
# Without a MULTIPLEXER entry in the manifest, tmux fails at config-validate
# with a fix-naming message (ADR-001 fail-loud).
#
# Isolation (rip-cage-61al.4 review, Finding 2):
#   RC_MUX_INSPECT_IMAGE is pinned to a nonexistent tag so _config_mux_derive_allowed_set
#   takes the image-absent path deterministically (not the host's rip-cage:latest label).
#   RC_MANIFEST_GLOBAL is pinned to a controlled empty manifest (no MULTIPLEXER entries)
#   so the manifest fallback does not read the developer's real ~/.config/rip-cage/tools.yaml.
# -----------------------------------------------
echo ""
echo "=== Test 2: session.multiplexer=tmux without manifest declaration fails loud ==="

T2_WKSP=$(mktemp -d)
T2_GLOBAL_CFG=$(mktemp "${TMPDIR:-/tmp}/rc-prereq-t2-XXXXXX.yaml")
T2_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/rc-prereq-t2-manifest-XXXXXX.yaml")
mkdir -p "${T2_WKSP}/.git"
printf 'version: 1\nsession:\n  multiplexer: tmux\nmounts:\n  denylist: []\n' > "${T2_WKSP}/.rip-cage.yaml"
printf 'version: 1\nmounts:\n  denylist: []\n' > "$T2_GLOBAL_CFG"
# Empty manifest: no tools / no MULTIPLEXER entries.
printf 'version: 1\ntools: []\n' > "$T2_MANIFEST"
output=$(RC_ALLOWED_ROOTS="$T2_WKSP" RC_CONFIG_GLOBAL="$T2_GLOBAL_CFG" \
  RC_MUX_INSPECT_IMAGE="rip-cage:nonexistent-isolation-prereq-t2" \
  RC_MANIFEST_GLOBAL="$T2_MANIFEST" \
  "$RC" up "$T2_WKSP" 2>&1 || true)
rm -f "$T2_GLOBAL_CFG" "$T2_MANIFEST"
if echo "$output" | grep -qi "tmux"; then
  pass "missing tmux manifest entry: error mentions 'tmux'"
else
  fail "missing tmux manifest entry: error should mention 'tmux'" "$output"
fi
if echo "$output" | grep -q "rc build"; then
  pass "missing tmux manifest entry: error names the fix ('rc build')"
else
  fail "missing tmux manifest entry: error should name the fix 'rc build'" "$output"
fi

# -----------------------------------------------
# Test 3: Docker daemon not running — rc build fails with helpful message
# rip-cage-tsf2.1: `rc ls` moved from check_docker to check_msb (ADR-029 D1
# hard cutover). `rc build` is the one remaining verb that genuinely still
# runs `docker build`, so it's the real check_docker exerciser now; Test 3b
# below covers `rc ls`'s new msb-side daemon-error surfacing.
# -----------------------------------------------
echo ""
echo "=== Test 3: Docker daemon not running gives helpful error ==="

output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" build 2>&1 || true)
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
# Test 3b: msb runtime not reachable — rc ls fails with a helpful,
# msb-specific message (rip-cage-tsf2.1).
# -----------------------------------------------
echo ""
echo "=== Test 3b: msb not reachable gives a helpful msb-specific error ==="

FAKE_MSB_BIN=$(mktemp -d)
cat > "$FAKE_MSB_BIN/msb" <<'FAKEMSB'
#!/usr/bin/env bash
echo "msb: connection refused" >&2
exit 1
FAKEMSB
chmod +x "$FAKE_MSB_BIN/msb"

output=$(PATH="$FAKE_MSB_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" ls 2>&1 || true)
if echo "$output" | grep -qi "msb"; then
  pass "msb not reachable: error mentions 'msb'"
else
  fail "msb not reachable: error should mention 'msb'" "$output"
fi
if echo "$output" | grep -qi "reachable\|unresponsive"; then
  pass "msb not reachable: error mentions reachability status"
else
  fail "msb not reachable: error should mention reachability status" "$output"
fi
rm -rf "$FAKE_MSB_BIN"

# -----------------------------------------------
# Test 4: Commands that need docker check it (build); commands rewired onto
# msb by rip-cage-tsf2.1 check msb instead (ls, attach, down, destroy, test)
# -----------------------------------------------
echo ""
echo "=== Test 4: Docker check runs for build; msb check runs for the msb-rewired verbs ==="

output=$(PATH="$FAKE_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" build 2>&1 || true)
if echo "$output" | grep -qi "docker"; then
  pass "docker check for 'rc build'"
else
  fail "docker check for 'rc build'" "$output"
fi

FAKE_MSB_BIN=$(mktemp -d)
cat > "$FAKE_MSB_BIN/msb" <<'FAKEMSB'
#!/usr/bin/env bash
echo "msb: connection refused" >&2
exit 1
FAKEMSB
chmod +x "$FAKE_MSB_BIN/msb"

# ls gets a clean error; attach/down/destroy/test need an arg but still hit
# the msb check first.
for cmd in ls attach down destroy test; do
  output=$(PATH="$FAKE_MSB_BIN:$PATH" RC_ALLOWED_ROOTS="$HOME" "$RC" $cmd 2>&1 || true)
  if echo "$output" | grep -qi "msb"; then
    pass "msb check for 'rc $cmd'"
  else
    fail "msb check for 'rc $cmd'" "$output"
  fi
done
rm -rf "$FAKE_MSB_BIN"

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
# Test 6: rc init is removed — verify it errors (rip-cage-kt25)
# -----------------------------------------------
echo ""
echo "=== Test 6: rc init returns unknown-command (removed in rip-cage-kt25) ==="

output=$("$RC" init 2>&1 || true)
if echo "$output" | grep -q "build"; then
  pass "rc init falls through to usage (unknown command)"
else
  fail "rc init did not produce usage output: $output"
fi

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
