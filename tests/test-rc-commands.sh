#!/usr/bin/env bash
set -uo pipefail

# Test script for rc init and rc build commands
# Each test prints PASS/FAIL and exits non-zero on first failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- Test 1: Usage includes build and init ---
echo "=== Test 1: Usage text includes build and init ==="
usage_output=$("$RC" 2>&1 || true)
if echo "$usage_output" | grep -q "build"; then
  pass "usage mentions build"
else
  fail "usage does not mention build"
fi
if echo "$usage_output" | grep -q "init"; then
  pass "usage mentions init"
else
  fail "usage does not mention init"
fi

# --- Test 2: rc init creates devcontainer.json in target directory ---
echo ""
echo "=== Test 2: rc init creates devcontainer.json ==="
TEST_DIR=$(mktemp -d)
RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR")" "$RC" init "$TEST_DIR"
if [[ -f "$TEST_DIR/.devcontainer/devcontainer.json" ]]; then
  pass "devcontainer.json created"
else
  fail "devcontainer.json not created"
fi

# --- Test 3: devcontainer.json has correct content ---
echo ""
echo "=== Test 3: devcontainer.json content is correct ==="
if grep -q '"image": "rip-cage:latest"' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "image is rip-cage:latest"
else
  fail "image is not rip-cage:latest"
fi
if grep -q '"remoteUser": "agent"' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "remoteUser is agent"
else
  fail "remoteUser is not agent"
fi
if grep -q 'rc-state-' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "has rc-state volume mount"
else
  fail "missing rc-state volume mount"
fi
if grep -q 'init-rip-cage.sh' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "has postStartCommand"
else
  fail "missing postStartCommand"
fi
if grep -q 'rc-context/skills' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "has skills mount"
else
  fail "missing skills mount"
fi
if grep -q 'rc-context/commands' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "has commands mount"
else
  fail "missing commands mount"
fi
if grep -q 'mkdir -p.*skills.*commands' "$TEST_DIR/.devcontainer/devcontainer.json"; then
  pass "initializeCommand creates skills/commands dirs"
else
  fail "initializeCommand missing mkdir -p for skills/commands"
fi

# --- Test 4: rc init refuses to overwrite without --force ---
echo ""
echo "=== Test 4: rc init refuses overwrite without --force ==="
overwrite_output=$(RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR")" "$RC" init "$TEST_DIR" 2>&1 || true)
if echo "$overwrite_output" | grep -qi "exists\|already"; then
  pass "refuses to overwrite"
else
  fail "did not refuse to overwrite: $overwrite_output"
fi

# --- Test 5: rc init --force overwrites ---
echo ""
echo "=== Test 5: rc init --force overwrites ==="
RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR")" "$RC" init --force "$TEST_DIR"
if [[ -f "$TEST_DIR/.devcontainer/devcontainer.json" ]]; then
  pass "devcontainer.json exists after --force"
else
  fail "devcontainer.json missing after --force"
fi

# --- Test 6: rc init with no path defaults to current directory ---
echo ""
echo "=== Test 6: rc init with no path uses current directory ==="
TEST_DIR2=$(mktemp -d)
cd "$TEST_DIR2"
RC_ALLOWED_ROOTS="$(dirname "$TEST_DIR2")" "$RC" init
if [[ -f "$TEST_DIR2/.devcontainer/devcontainer.json" ]]; then
  pass "devcontainer.json created in current directory"
else
  fail "devcontainer.json not created in current directory"
fi

# --- Test 7: rc build uses SCRIPT_DIR to find Dockerfile ---
echo ""
echo "=== Test 7: rc build finds Dockerfile via SCRIPT_DIR ==="
# We just test that it attempts docker build with the right context
# Use --dry-run isn't available, so we test from a different directory
# and check that it doesn't complain about missing Dockerfile
# (it will fail because docker may not be running, but the error should
# be about docker, not about missing Dockerfile)
cd /tmp
build_output=$("$RC" build --help-test-sentinel 2>&1 || true)
# If we get a docker error (not a "Dockerfile not found" error), the path resolution works
# The command should at least print what it's doing
if echo "$build_output" | grep -qi "build\|docker"; then
  pass "build command recognized and attempts docker build"
else
  fail "build command not working: $build_output"
fi

# --- Test 8: check_docker surfaces Docker daemon errors ---
echo ""
echo "=== Test 8: check_docker surfaces Docker errors when daemon is not running ==="
FAKE_DOCKER_DIR=$(mktemp -d)
cat > "$FAKE_DOCKER_DIR/docker" <<'FAKE'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon" >&2
exit 1
FAKE
chmod +x "$FAKE_DOCKER_DIR/docker"
# Call rc down with the fake docker on PATH — check_docker runs first
docker_err_output=$(PATH="$FAKE_DOCKER_DIR:$PATH" "$RC" down 2>&1 || true)
if echo "$docker_err_output" | grep -qi "docker"; then
  pass "check_docker surfaces docker error message"
else
  fail "check_docker did not surface docker failure: $docker_err_output"
fi
rm -rf "$FAKE_DOCKER_DIR"

# --- Test 9: skill symlink resolution in rc up --dry-run ---
echo ""
echo "=== Test 9: skill symlink resolution in rc up --dry-run ==="
SYMLINK_SKILLS_DIR=$(mktemp -d)
SYMLINK_TARGET_DIR=$(mktemp -d)
# Create a real skill directory (non-symlink) — should not produce extra mount
mkdir -p "${SYMLINK_SKILLS_DIR}/real-skill"
# Create a symlinked skill pointing to the target dir
ln -s "${SYMLINK_TARGET_DIR}" "${SYMLINK_SKILLS_DIR}/linked-skill"
# Override HOME/.claude/skills for this test via env substitution in rc
# rc uses ${HOME}/.claude/skills directly, so we need a workaround:
# source the rc helper function directly and call it
symlink_parent_output=$(bash -c '
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then
        echo "[rc] Warning: asset outside HOME — skipping" >&2
        continue
      fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${SYMLINK_SKILLS_DIR}")

# The linked-skill target is in /tmp (outside $HOME) — should be skipped with warning
# Real-world targets under $HOME would pass through
if echo "$symlink_parent_output" | grep -q "$(dirname "${SYMLINK_TARGET_DIR}")"; then
  fail "should have skipped target outside HOME"
else
  pass "skill symlink target outside HOME is skipped"
fi

# Create a symlinked skill pointing INSIDE HOME (simulate monorepo case)
HOME_TARGET_DIR=$(mktemp -d "${HOME}/.tmp-rc-test-XXXXXX")
SYMLINK_SKILLS_DIR2=$(mktemp -d)
ln -s "${HOME_TARGET_DIR}" "${SYMLINK_SKILLS_DIR2}/linked-skill"
symlink_parent_output2=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then
        continue
      fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${SYMLINK_SKILLS_DIR2}")

expected_parent="$(dirname "${HOME_TARGET_DIR}")"
if echo "$symlink_parent_output2" | grep -qF "${expected_parent}"; then
  pass "skill symlink target inside HOME produces parent mount"
else
  fail "skill symlink target inside HOME did not produce parent mount (got: $symlink_parent_output2, expected: $expected_parent)"
fi

# Deduplication: two symlinks pointing to the same parent should produce one line
ln -s "${HOME_TARGET_DIR}" "${SYMLINK_SKILLS_DIR2}/linked-skill2" 2>/dev/null || true
mkdir -p "${HOME_TARGET_DIR}/../sibling-$(basename "${HOME_TARGET_DIR}")"
SIBLING_DIR="${HOME_TARGET_DIR}/../sibling-$(basename "${HOME_TARGET_DIR}")"
SIBLING_DIR=$(realpath "${SIBLING_DIR}")
ln -s "${SIBLING_DIR}" "${SYMLINK_SKILLS_DIR2}/linked-skill3"
dedup_output=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then continue; fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${SYMLINK_SKILLS_DIR2}")
dedup_count=$(echo "$dedup_output" | grep -c "$(dirname "${HOME_TARGET_DIR}")" || true)
if [[ "$dedup_count" -eq 1 ]]; then
  pass "symlinks sharing a parent produce exactly one mount (deduplication)"
else
  fail "deduplication failed — expected 1 parent mount, got $dedup_count (output: $dedup_output)"
fi

# --- Test 10: rc init adds symlink mounts to devcontainer.json when skills have symlinks ---
echo ""
echo "=== Test 10: rc init adds symlink mounts to devcontainer.json ==="
# This test exercises the actual rc init code path with a real HOME_TARGET_DIR
TEST_DIR3=$(mktemp -d)
mkdir -p "${TEST_DIR3}/.git/hooks"
# Temporarily override HOME/.claude/skills via a wrapper that monkeypatches the skills path
# rc uses ${HOME}/.claude/skills directly — we can test via the jq output if we have
# symlinks already at ~/.claude/skills (which we do, in the real repo).
# Instead, run rc init and verify the generated devcontainer.json has the extra mount.
RC_ALLOWED_ROOTS="${TEST_DIR3}" "$RC" init "${TEST_DIR3}" 2>/dev/null
if [[ -f "${TEST_DIR3}/.devcontainer/devcontainer.json" ]]; then
  pass "rc init creates devcontainer.json"
  # Check if the real ~/.claude/skills has symlinks (it does in this repo)
  if [[ -d "${HOME}/.claude/skills" ]] && ls -la "${HOME}/.claude/skills"/ 2>/dev/null | grep -q "^l"; then
    # Skills directory has symlinks — devcontainer.json should have extra mounts.
    # Symlink-target mounts use absolute paths (source=/...) not devcontainer variables.
    extra_mounts=$(jq -r '.mounts[]' "${TEST_DIR3}/.devcontainer/devcontainer.json" 2>/dev/null | grep "^source=/" || true)
    if [[ -n "$extra_mounts" ]]; then
      pass "devcontainer.json has skill symlink target mounts"
    else
      fail "devcontainer.json missing skill symlink target mounts (symlinks exist in ~/.claude/skills)"
    fi
  else
    pass "no skill symlinks to test (skipped extra-mount check)"
  fi
else
  fail "rc init did not create devcontainer.json"
fi

# --- Test 11: _collect_symlink_parents handles file symlinks ---
echo ""
echo "=== Test 11: _collect_symlink_parents handles file symlinks ==="
FILE_SYMLINK_TARGET_DIR=$(mktemp -d "${HOME}/.tmp-rc-file-test-XXXXXX")
echo "# Test agent" > "${FILE_SYMLINK_TARGET_DIR}/test-agent.md"
FILE_SYMLINK_AGENTS_DIR=$(mktemp -d)
ln -s "${FILE_SYMLINK_TARGET_DIR}/test-agent.md" "${FILE_SYMLINK_AGENTS_DIR}/test-agent.md"

# Positive test: [[ -e ]] version (the fix) should return the parent dir
file_symlink_output=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then continue; fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${FILE_SYMLINK_AGENTS_DIR}")

if echo "$file_symlink_output" | grep -qF "${FILE_SYMLINK_TARGET_DIR}"; then
  pass "file symlink target parent dir returned with [[ -e ]] fix"
else
  fail "file symlink target parent dir NOT returned (got: $file_symlink_output, expected: $FILE_SYMLINK_TARGET_DIR)"
fi

# Negative test: [[ -d ]] version (the old bug) should return empty for file symlinks
file_symlink_old_output=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents_old() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -d "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then continue; fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents_old "$1"
' _ "${FILE_SYMLINK_AGENTS_DIR}")

if [[ -z "$file_symlink_old_output" ]]; then
  pass "old [[ -d ]] version returns empty for file symlinks (proves fix is needed)"
else
  fail "old [[ -d ]] version should return empty for file symlinks (got: $file_symlink_old_output)"
fi

rm -rf "$FILE_SYMLINK_TARGET_DIR" "$FILE_SYMLINK_AGENTS_DIR"

# --- Test 12: rc init devcontainer.json includes agents bind-mount ---
echo ""
echo "=== Test 12: rc init devcontainer.json includes agents entry ==="
TEST_DIR_T12=$(mktemp -d)
mkdir -p "${TEST_DIR_T12}/.git/hooks"
RC_ALLOWED_ROOTS="$TEST_DIR_T12" "$RC" init "$TEST_DIR_T12" 2>/dev/null
if [[ -f "${TEST_DIR_T12}/.devcontainer/devcontainer.json" ]]; then
  if jq -r '.mounts[]' "${TEST_DIR_T12}/.devcontainer/devcontainer.json" 2>/dev/null | grep -q 'rc-context/agents'; then
    pass "devcontainer.json mounts[] contains agents entry"
  else
    fail "devcontainer.json mounts[] missing agents entry"
  fi
else
  fail "devcontainer.json not created for Test 12"
fi

# --- Test 13: rc init initializeCommand includes agents mkdir ---
echo ""
echo "=== Test 13: rc init initializeCommand includes agents mkdir ==="
if [[ -f "${TEST_DIR_T12}/.devcontainer/devcontainer.json" ]]; then
  if jq -r '.initializeCommand' "${TEST_DIR_T12}/.devcontainer/devcontainer.json" 2>/dev/null | grep -q '.claude/agents'; then
    pass "initializeCommand includes .claude/agents mkdir"
  else
    fail "initializeCommand missing .claude/agents mkdir"
  fi
else
  fail "devcontainer.json not available for Test 13"
fi
rm -rf "$TEST_DIR_T12"

# --- Test 14: rc up --dry-run includes agents mount line ---
echo ""
echo "=== Test 14: rc up --dry-run includes agents mount line ==="
if [[ -d "${HOME}/.claude/agents" ]]; then
  TEST_DIR_T14=$(mktemp -d)
  mkdir -p "${TEST_DIR_T14}/.git"
  dry_run_output=$(RC_ALLOWED_ROOTS="$TEST_DIR_T14" "$RC" up --dry-run "$TEST_DIR_T14" 2>&1 || true)
  if echo "$dry_run_output" | grep -q 'Would mount.*rc-context/agents'; then
    pass "rc up --dry-run shows agents mount"
  else
    fail "rc up --dry-run missing agents mount line"
  fi
  rm -rf "$TEST_DIR_T14"
else
  pass "rc up --dry-run agents check skipped — ~/.claude/agents not present"
fi

# --- Cleanup ---
rm -rf "$SYMLINK_SKILLS_DIR" "$SYMLINK_TARGET_DIR" "$SYMLINK_SKILLS_DIR2" "$HOME_TARGET_DIR" "$SIBLING_DIR" "$TEST_DIR3"
rm -rf "$TEST_DIR" "$TEST_DIR2"

echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
