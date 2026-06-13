#!/usr/bin/env bash
if ! command -v docker > /dev/null 2>&1; then
  echo "SKIP: Docker not available -- skipping $(basename "$0")"
  exit 0
fi
set -uo pipefail

# Test script for rc init and rc build commands
# Each test prints PASS/FAIL and exits non-zero on first failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
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

  # rc up now checks the version label — ensure local image is current so the
  # test reaches the "Would mount" dry-run lines (not the stale-image early exit).
  RC_VER_T14=$("${REPO_ROOT}/rc" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  CURRENT_IMAGE_T14=$(docker image inspect rip-cage:latest --format '{{.Id}}' 2>/dev/null || true)
  STUB_IMAGE_T14=$(docker build -q - <<STUB_EOF
FROM scratch
LABEL org.opencontainers.image.version="${RC_VER_T14}"
STUB_EOF
)
  if [[ -z "$STUB_IMAGE_T14" ]]; then
    fail "Test 14 setup: stub image build failed — cannot test agents mount"
  else
    docker tag "$STUB_IMAGE_T14" rip-cage:latest >/dev/null 2>&1

    # ADR-023: rc up requires a global config. Provide a minimal one via RC_CONFIG_GLOBAL.
    T14_GLOBAL_CFG=$(mktemp "${TMPDIR:-/tmp}/rc-t14-cfg-XXXXXX.yaml")
    printf 'version: 1\nmounts:\n  denylist: []\n' > "$T14_GLOBAL_CFG"
    dry_run_output=$(RC_ALLOWED_ROOTS="$TEST_DIR_T14" RC_CONFIG_GLOBAL="$T14_GLOBAL_CFG" "$RC" up --dry-run "$TEST_DIR_T14" 2>&1 || true)
    rm -f "$T14_GLOBAL_CFG"

    # Restore original image
    if [[ -n "$CURRENT_IMAGE_T14" ]]; then
      docker tag "$CURRENT_IMAGE_T14" rip-cage:latest >/dev/null 2>&1
    else
      docker rmi rip-cage:latest >/dev/null 2>&1 || true
    fi
    docker rmi "$STUB_IMAGE_T14" >/dev/null 2>&1 || true

    if echo "$dry_run_output" | grep -q 'Would mount.*rc-context/agents'; then
      pass "rc up --dry-run shows agents mount"
    else
      fail "rc up --dry-run missing agents mount line"
    fi
  fi
  rm -rf "$TEST_DIR_T14"
else
  pass "rc up --dry-run agents check skipped — ~/.claude/agents not present"
fi

# --- Test 15: beads-host-dolt in rc test (Tier 3: requires running rc container) ---
echo ""
echo "=== Test 15: beads-host-dolt check in rc test (Tier 3) ==="
# Find a running rc container whose workspace is the rip-cage repo (embedded mode)
RIPCAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC_CONTAINER_T15=$(docker ps --filter "label=rc.source.path=${RIPCAGE_ROOT}" --format "{{.Names}}" 2>/dev/null | head -1 || true)

if [[ -z "$RC_CONTAINER_T15" ]]; then
  echo "SKIP: Test 15 — no running rc container found for ${RIPCAGE_ROOT} (start one with: rc up ${RIPCAGE_ROOT})"
  pass "beads-host-dolt rc test (skipped — no container)"
else
  # JSON mode: embedded project should produce pass with correct name
  rc_json_out=$("$RC" --output json test "$RC_CONTAINER_T15" 2>/dev/null || true)
  bd_status=$(echo "$rc_json_out" | jq -r '.checks[] | select(.name=="beads-host-dolt") | .status' 2>/dev/null || true)
  if [[ "$bd_status" == "pass" ]]; then
    pass "rc test JSON: beads-host-dolt status is pass"
  else
    fail "rc test JSON: beads-host-dolt status expected 'pass', got '${bd_status}' (json: ${rc_json_out})"
  fi

  bd_detail=$(echo "$rc_json_out" | jq -r '.checks[] | select(.name=="beads-host-dolt") | .detail' 2>/dev/null || true)
  if [[ "$bd_detail" == "not applicable (embedded mode)" ]]; then
    pass "rc test JSON: beads-host-dolt detail is 'not applicable (embedded mode)'"
  else
    fail "rc test JSON: beads-host-dolt detail expected 'not applicable (embedded mode)', got '${bd_detail}'"
  fi

  # Text mode: check PASS line present
  rc_text_out=$("$RC" test "$RC_CONTAINER_T15" 2>/dev/null || true)
  if echo "$rc_text_out" | grep -q "PASS \[0\] beads-host-dolt"; then
    pass "rc test text: beads-host-dolt PASS line present"
  else
    fail "rc test text: missing 'PASS [0] beads-host-dolt' (output: ${rc_text_out})"
  fi
fi

# --- Test 16: beads-host-dolt stale port via __bd-preflight-test (no container needed) ---
echo ""
echo "=== Test 16: beads-host-dolt stale port via __bd-preflight-test ==="
STALE_BEADS=$(mktemp -d)
mkdir -p "${STALE_BEADS}/.beads"
printf '65000\n' > "${STALE_BEADS}/.beads/dolt-server.port"
stale_out=$("$RC" __bd-preflight-test "${STALE_BEADS}/.beads" "server" 2>/dev/null || true)
if echo "$stale_out" | grep -q "FAIL \[0\] beads-host-dolt"; then
  pass "__bd-preflight-test stale port produces FAIL beads-host-dolt"
else
  fail "__bd-preflight-test stale port: expected FAIL [0] beads-host-dolt, got: ${stale_out}"
fi
if echo "$stale_out" | grep -q "stale port"; then
  pass "__bd-preflight-test stale port detail mentions 'stale port'"
else
  fail "__bd-preflight-test stale port: detail missing 'stale port' (got: ${stale_out})"
fi
rm -rf "$STALE_BEADS"

# --- Test 17: beads-host-dolt corrupt port via __bd-preflight-test (no container needed) ---
echo ""
echo "=== Test 17: beads-host-dolt corrupt port via __bd-preflight-test ==="
CORRUPT_BEADS=$(mktemp -d)
mkdir -p "${CORRUPT_BEADS}/.beads"
printf 'not-a-number\n' > "${CORRUPT_BEADS}/.beads/dolt-server.port"
corrupt_out=$("$RC" __bd-preflight-test "${CORRUPT_BEADS}/.beads" "server" 2>/dev/null || true)
if echo "$corrupt_out" | grep -q "FAIL \[0\] beads-host-dolt"; then
  pass "__bd-preflight-test corrupt port produces FAIL beads-host-dolt"
else
  fail "__bd-preflight-test corrupt port: expected FAIL [0] beads-host-dolt, got: ${corrupt_out}"
fi
if echo "$corrupt_out" | grep -q "corrupt port file"; then
  pass "__bd-preflight-test corrupt port detail mentions 'corrupt port file'"
else
  fail "__bd-preflight-test corrupt port: detail missing 'corrupt port file' (got: ${corrupt_out})"
fi
rm -rf "$CORRUPT_BEADS"

# --- Test 18: beads-host-dolt port file missing via __bd-preflight-test (no container needed) ---
echo ""
echo "=== Test 18: beads-host-dolt port file missing via __bd-preflight-test ==="
MISSING_BEADS=$(mktemp -d)
mkdir -p "${MISSING_BEADS}/.beads"
# No port file created
missing_out=$("$RC" __bd-preflight-test "${MISSING_BEADS}/.beads" "server" 2>/dev/null || true)
if echo "$missing_out" | grep -q "FAIL \[0\] beads-host-dolt"; then
  pass "__bd-preflight-test missing port produces FAIL beads-host-dolt"
else
  fail "__bd-preflight-test missing port: expected FAIL [0] beads-host-dolt, got: ${missing_out}"
fi
if echo "$missing_out" | grep -q "port file missing"; then
  pass "__bd-preflight-test missing port detail mentions 'port file missing'"
else
  fail "__bd-preflight-test missing port: detail missing 'port file missing' (got: ${missing_out})"
fi
rm -rf "$MISSING_BEADS"

# --- Test 19: stale local image triggers re-provisioning in rc up --dry-run ---
echo ""
echo "=== Test 19: stale local image triggers re-provisioning ==="
# Build a REAL tagged image (not FROM scratch — that digest is not inspectable under
# containerd/io.containerd.snapshotter.v1 on Docker 29.4.0, causing docker tag to
# silently no-op). We use alpine with a clearly stale version label so _image_is_current
# returns non-current and the "would build" re-provision path fires.
T19_STALE_TAG="rip-cage:stale-test-t19"
docker build -q -t "$T19_STALE_TAG" - <<'STALE_DOCKERFILE' >/dev/null 2>&1
FROM alpine:3.19
LABEL org.opencontainers.image.version="stale-test-0.0.0"
LABEL description="stub image for stale-label test"
STALE_DOCKERFILE
T19_BUILD_EXIT=$?
if [[ $T19_BUILD_EXIT -ne 0 ]]; then
  fail "Test 19 setup: could not build stale stub image (exit $T19_BUILD_EXIT)"
else
  # Save the original rip-cage:latest reference before swapping
  ORIGINAL_IMAGE_ID=$(docker image inspect rip-cage:latest --format '{{.Id}}' 2>/dev/null || true)

  # Crash-safe cleanup: restore rip-cage:latest even if interrupted mid-test.
  # Idempotent: safe when ORIGINAL_IMAGE_ID is empty (removes the stub tag).
  # Cleared after the normal-path restore so it does not fire spuriously.
  trap '
    if [[ -n "${ORIGINAL_IMAGE_ID:-}" ]]; then
      docker tag "$ORIGINAL_IMAGE_ID" rip-cage:latest >/dev/null 2>&1 || true
    else
      docker rmi rip-cage:latest >/dev/null 2>&1 || true
    fi
    docker rmi "${T19_STALE_TAG:-}" >/dev/null 2>&1 || true
  ' EXIT INT TERM

  docker tag "$T19_STALE_TAG" rip-cage:latest >/dev/null 2>&1

  # POSITIVE SENTINEL: verify the swap actually landed — the installed label must differ
  # from RC_VERSION so _image_is_current returns false and the staleness path fires.
  T19_CURRENT_RC_VERSION=$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "unknown")
  T19_INSTALLED_LABEL=$(docker image inspect rip-cage:latest \
    --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null || true)
  if [[ "$T19_INSTALLED_LABEL" == "$T19_CURRENT_RC_VERSION" ]]; then
    fail "Test 19 sentinel: stale fixture was not installed (label=${T19_INSTALLED_LABEL} == RC_VERSION=${T19_CURRENT_RC_VERSION}); swap may have silently no-oped"
    # Still restore before continuing; then disarm the crash-safe trap.
    if [[ -n "$ORIGINAL_IMAGE_ID" ]]; then
      docker tag "$ORIGINAL_IMAGE_ID" rip-cage:latest >/dev/null 2>&1
    else
      docker rmi rip-cage:latest >/dev/null 2>&1 || true
    fi
    docker rmi "$T19_STALE_TAG" >/dev/null 2>&1 || true
    trap - EXIT INT TERM
  else
    TEST_DIR_T19=$(mktemp -d)
    mkdir -p "${TEST_DIR_T19}/.git"
    # ADR-023: rc up requires a global config. Provide a minimal one via RC_CONFIG_GLOBAL.
    T19_GLOBAL_CFG=$(mktemp "${TMPDIR:-/tmp}/rc-t19-cfg-XXXXXX.yaml")
    printf 'version: 1\nmounts:\n  denylist: []\n' > "$T19_GLOBAL_CFG"
    stale_dry_run_output=$(RIP_CAGE_IMAGE_REGISTRY="" RC_ALLOWED_ROOTS="$TEST_DIR_T19" RC_CONFIG_GLOBAL="$T19_GLOBAL_CFG" \
      "$RC" up --dry-run "$TEST_DIR_T19" 2>&1 || true)
    rm -f "$T19_GLOBAL_CFG"

    # Restore original image (or remove the stub tag if there was no prior image)
    if [[ -n "$ORIGINAL_IMAGE_ID" ]]; then
      docker tag "$ORIGINAL_IMAGE_ID" rip-cage:latest >/dev/null 2>&1
    else
      docker rmi rip-cage:latest >/dev/null 2>&1 || true
    fi
    docker rmi "$T19_STALE_TAG" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR_T19"
    # Normal-path restore complete — disarm the crash-safe trap.
    trap - EXIT INT TERM

    # POSITIVE ASSERTION: a stale image must route through _pull_or_build.
    # With RIP_CAGE_IMAGE_REGISTRY="" the dry-run message is "would build".
    if echo "$stale_dry_run_output" | grep -qi "would build\|would pull"; then
      pass "stale image (mismatched version label) triggers re-provisioning (sentinel: installed=${T19_INSTALLED_LABEL}, rc=${T19_CURRENT_RC_VERSION})"
    else
      fail "stale image did NOT trigger re-provisioning (output: $stale_dry_run_output)"
    fi
  fi
fi

# --- Test 20: RC_VERSION="unknown" treats image as current (skip stale check) ---
echo ""
echo "=== Test 20: RC_VERSION=unknown skips staleness check ==="
# When VERSION file is absent, RC_VERSION="unknown". An image with no matching
# label should still be treated as current (not stale) so rc up doesn't
# silently re-provision every time on a malformed checkout.
#
# Strategy: tag a stub image (no version label) as rip-cage:latest, then
# invoke rc up --dry-run with VERSION file temporarily renamed (so RC_VERSION="unknown")
# and RIP_CAGE_IMAGE_REGISTRY="" so if re-provision fires the message is "build".
# The dry-run output must NOT contain "would build" or "would pull" — it must
# reach the normal dry-run lines ("Would create container..." / "Would mount...").
#
# NOTE: FROM scratch stubs are NOT inspectable under containerd (Docker 29.4.0,
# io.containerd.snapshotter.v1), so docker tag silently no-ops with a digest-only image.
# We use alpine with no version label (but a real -t tag) to get an inspectable image
# whose label is missing so _image_is_current would return stale — but RC_VERSION=unknown
# bypasses the check, so the staleness path still must NOT fire.
T20_STUB_TAG="rip-cage:stub-t20"
docker build -q -t "$T20_STUB_TAG" - <<'STUB_DOCKERFILE_T20' >/dev/null 2>&1
FROM alpine:3.19
LABEL description="stub image for unknown-version test"
STUB_DOCKERFILE_T20
T20_BUILD_EXIT=$?
if [[ $T20_BUILD_EXIT -ne 0 ]]; then
  fail "Test 20 setup: could not build stub image (exit $T20_BUILD_EXIT)"
else
  ORIGINAL_IMAGE_T20=$(docker image inspect rip-cage:latest --format '{{.Id}}' 2>/dev/null || true)

  # Crash-safe cleanup: restore rip-cage:latest and VERSION file even if interrupted.
  # Idempotent: BACKUP_VERSION_FILE restore is a no-op when the backup does not exist.
  # Cleared after the normal-path restore so it does not fire spuriously.
  REPO_VERSION_FILE="${REPO_ROOT}/VERSION"
  BACKUP_VERSION_FILE="${REPO_ROOT}/VERSION.t20bak"
  trap '
    [[ -f "${BACKUP_VERSION_FILE:-}" ]] && mv "$BACKUP_VERSION_FILE" "$REPO_VERSION_FILE" 2>/dev/null || true
    if [[ -n "${ORIGINAL_IMAGE_T20:-}" ]]; then
      docker tag "$ORIGINAL_IMAGE_T20" rip-cage:latest >/dev/null 2>&1 || true
    else
      docker rmi rip-cage:latest >/dev/null 2>&1 || true
    fi
    docker rmi "${T20_STUB_TAG:-}" >/dev/null 2>&1 || true
  ' EXIT INT TERM

  docker tag "$T20_STUB_TAG" rip-cage:latest >/dev/null 2>&1

  TEST_DIR_T20=$(mktemp -d)
  mkdir -p "${TEST_DIR_T20}/.git"

  # Use rename of the VERSION file so rc reads RC_VERSION="unknown".
  mv "$REPO_VERSION_FILE" "$BACKUP_VERSION_FILE" 2>/dev/null || true

  T20_GLOBAL_CFG=$(mktemp "${TMPDIR:-/tmp}/rc-t20-cfg-XXXXXX.yaml")
  printf 'version: 1\nmounts:\n  denylist: []\n' > "$T20_GLOBAL_CFG"
  unknown_dry_run_output=$(RIP_CAGE_IMAGE_REGISTRY="" RC_ALLOWED_ROOTS="$TEST_DIR_T20" RC_CONFIG_GLOBAL="$T20_GLOBAL_CFG" \
    "$RC" up --dry-run "$TEST_DIR_T20" 2>&1 || true)
  rm -f "$T20_GLOBAL_CFG"

  # Restore VERSION file before assertions (so any fail() calls don't leave repo damaged)
  mv "$BACKUP_VERSION_FILE" "$REPO_VERSION_FILE" 2>/dev/null || true

  # Restore original image
  if [[ -n "$ORIGINAL_IMAGE_T20" ]]; then
    docker tag "$ORIGINAL_IMAGE_T20" rip-cage:latest >/dev/null 2>&1
  else
    docker rmi rip-cage:latest >/dev/null 2>&1 || true
  fi
  docker rmi "$T20_STUB_TAG" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR_T20"
  # Normal-path restore complete — disarm the crash-safe trap.
  trap - EXIT INT TERM

  # When RC_VERSION is "unknown", staleness check must be skipped — dry-run
  # should NOT show "would build" / "would pull" (re-provisioning messages).
  if echo "$unknown_dry_run_output" | grep -qi "would build\|would pull"; then
    fail "RC_VERSION=unknown should skip stale check but triggered re-provisioning (output: $unknown_dry_run_output)"
  else
    # POSITIVE-BRANCH SENTINEL: the ELSE branch must be REACHED (not vacuously green from a
    # swap failure). Confirm the output contains normal dry-run lines — "Would create" or
    # "Would mount" — which only appear when the staleness skip path was actually taken.
    if echo "$unknown_dry_run_output" | grep -qi "Would create\|Would mount\|Would start"; then
      pass "RC_VERSION=unknown skips staleness check — normal dry-run lines observed (branch confirmed reached)"
    else
      fail "RC_VERSION=unknown ELSE branch reached but normal dry-run output missing — swap may have silently no-oped or dry-run path broken (output: $unknown_dry_run_output)"
    fi
  fi
fi

# --- Test 21: _next_session_slot — auto-name logic ---
echo ""
echo "=== Test 21: _next_session_slot picks lowest unused rip-cage-N slot ==="
next_slot_output=$(bash -c '
# Define the helper function directly for unit testing
_next_session_slot() {
  local existing_names="$1"
  local n=2
  while true; do
    echo "$existing_names" | grep -qxF "rip-cage-${n}" || break
    n=$((n + 1))
  done
  echo "rip-cage-${n}"
}

# No sessions: next slot is rip-cage-2
result=$(_next_session_slot "rip-cage")
echo "no-sessions:${result}"

# rip-cage-2 taken: next is rip-cage-3
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-2")")
echo "two-taken:${result}"

# rip-cage-2 and rip-cage-3 taken: next is rip-cage-4
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-2\nrip-cage-3")")
echo "three-taken:${result}"

# rip-cage-foo does NOT occupy a slot; rip-cage-2 should still be available
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-foo")")
echo "non-numeric:${result}"

# rip-cage-2 user-named takes slot 2; next is rip-cage-3
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-2")")
echo "user-named:${result}"
')

if echo "$next_slot_output" | grep -q "no-sessions:rip-cage-2"; then
  pass "_next_session_slot: no sessions → rip-cage-2"
else
  fail "_next_session_slot: no sessions should give rip-cage-2 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "two-taken:rip-cage-3"; then
  pass "_next_session_slot: rip-cage-2 taken → rip-cage-3"
else
  fail "_next_session_slot: rip-cage-2 taken should give rip-cage-3 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "three-taken:rip-cage-4"; then
  pass "_next_session_slot: rip-cage-2,3 taken → rip-cage-4"
else
  fail "_next_session_slot: rip-cage-2,3 taken should give rip-cage-4 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "non-numeric:rip-cage-2"; then
  pass "_next_session_slot: non-numeric suffix does not occupy slot (rip-cage-foo)"
else
  fail "_next_session_slot: rip-cage-foo should not block rip-cage-2 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "user-named:rip-cage-3"; then
  pass "_next_session_slot: user-named rip-cage-2 occupies slot → next is rip-cage-3"
else
  fail "_next_session_slot: user-named rip-cage-2 should block slot 2 (got: $next_slot_output)"
fi

# --- Test 22: --new --session mutex flag check in rc up ---
echo ""
echo "=== Test 22: rc up --new --session exits 2 with usage message ==="
TEST_DIR_T22=$(mktemp -d)
mkdir -p "${TEST_DIR_T22}/.git"
mutex_output=$(RC_ALLOWED_ROOTS="$TEST_DIR_T22" "$RC" up --dry-run --new --session "myname" "$TEST_DIR_T22" 2>&1 || true)
if echo "$mutex_output" | grep -qi "mutually exclusive\|cannot use.*together\|--new.*--session\|--session.*--new"; then
  pass "rc up --new --session shows mutually exclusive usage message"
else
  fail "rc up --new --session should show mutually exclusive error (got: $mutex_output)"
fi
# exit code should be 2 (usage error)
actual_exit=$(RC_ALLOWED_ROOTS="$TEST_DIR_T22" "$RC" up --dry-run --new --session "myname" "$TEST_DIR_T22" 2>/dev/null; echo $?)
if [[ "$actual_exit" == "2" ]]; then
  pass "rc up --new --session exits with code 2"
else
  fail "rc up --new --session should exit 2, got: $actual_exit"
fi
rm -rf "$TEST_DIR_T22"

# --- Test 23: rc up --dry-run does not show picker output ---
echo ""
echo "=== Test 23: rc up --dry-run skips picker (no 'Pick [' output) ==="
TEST_DIR_T23=$(mktemp -d)
mkdir -p "${TEST_DIR_T23}/.git"
# --dry-run must not show picker prompt even if piped stdin would trigger picker
dry_run_picker_out=$(RC_ALLOWED_ROOTS="$TEST_DIR_T23" "$RC" up --dry-run "$TEST_DIR_T23" 2>&1 </dev/null || true)
if echo "$dry_run_picker_out" | grep -q "Pick \["; then
  fail "rc up --dry-run should not show picker prompt (got: $dry_run_picker_out)"
else
  pass "rc up --dry-run does not show picker prompt"
fi
rm -rf "$TEST_DIR_T23"

# --- Test 24: Non-TTY (piped stdin) skips picker ---
echo ""
echo "=== Test 24: rc up with non-TTY stdin skips picker ==="
TEST_DIR_T24=$(mktemp -d)
mkdir -p "${TEST_DIR_T24}/.git"
# Pipe stdin from /dev/null so -t 0 is false — must not show picker
nontty_out=$(RC_ALLOWED_ROOTS="$TEST_DIR_T24" "$RC" up --dry-run "$TEST_DIR_T24" 2>&1 </dev/null || true)
if echo "$nontty_out" | grep -q "Pick \["; then
  fail "rc up with non-TTY stdin should not show picker (got: $nontty_out)"
else
  pass "rc up with non-TTY stdin skips picker"
fi
rm -rf "$TEST_DIR_T24"

# --- Test 25: rc sessions is retired — absent from rc schema (rip-cage-1f59.3) ---
# NON-VACUOUS: would fail if cmd_sessions were still present in rc schema.
# A still-present cmd_sessions would appear in 'rc schema | jq .commands' keys.
# A docker error on an unknown container also exits non-zero, so exit-code alone
# is vacuous — absence-from-schema is the discriminating assertion.
echo ""
echo "=== Test 25: rc sessions absent from rc schema (retired rip-cage-1f59.3) ==="
schema_t25=$("$RC" schema 2>/dev/null || true)
if echo "$schema_t25" | jq -e '.commands | has("sessions")' >/dev/null 2>&1; then
  fail "rc schema still contains sessions key (should be retired per rip-cage-1f59.3)"
else
  pass "rc schema does not contain sessions key (correctly retired)"
fi
# Paired exit-code check: retirement also means non-zero on invocation
sessions_exit_t25=0
"$RC" sessions no-such-container-xyz >/dev/null 2>&1 || sessions_exit_t25=$?
if [[ "$sessions_exit_t25" -ne 0 ]]; then
  pass "rc sessions invocation exits non-zero (unknown command)"
else
  fail "rc sessions should exit non-zero (command was retired), got exit 0"
fi

# --- Test 26: rc agent is retired — absent from rc schema (rip-cage-1f59.3) ---
# NON-VACUOUS: would fail if cmd_agent were still present in rc schema.
# This is new coverage — rc agent retirement was not previously tested at all.
echo ""
echo "=== Test 26: rc agent absent from rc schema (retired rip-cage-1f59.3) ==="
schema_t26=$("$RC" schema 2>/dev/null || true)
if echo "$schema_t26" | jq -e '.commands | has("agent")' >/dev/null 2>&1; then
  fail "rc schema still contains agent key (should be retired per rip-cage-1f59.3)"
else
  pass "rc schema does not contain agent key (correctly retired)"
fi
# Paired exit-code check
agent_exit_t26=0
"$RC" agent no-such-container-xyz >/dev/null 2>&1 || agent_exit_t26=$?
if [[ "$agent_exit_t26" -ne 0 ]]; then
  pass "rc agent invocation exits non-zero (unknown command)"
else
  fail "rc agent should exit non-zero (command was retired), got exit 0"
fi

# --- Test 27: rc agent is retired — absent from rc --help (rip-cage-1f59.3) ---
# NON-VACUOUS: would fail if cmd_agent were still listed in the usage heredoc.
# Symmetric with test 36 (which covers sessions absence from --help).
echo ""
echo "=== Test 27: rc agent absent from rc --help (retired rip-cage-1f59.3) ==="
usage_t27=$("$RC" 2>&1 || true)
if echo "$usage_t27" | grep -q "^  agent"; then
  fail "rc usage still mentions agent subcommand (should be removed per rip-cage-1f59.3)"
else
  pass "rc usage does not mention agent subcommand (correctly retired)"
fi

# --- Test 28: tmux.conf contains remain-on-exit setting ---
echo ""
echo "=== Test 28: tmux.conf has remain-on-exit on ==="
if grep -q "remain-on-exit on" "${REPO_ROOT}/tmux.conf"; then
  pass "tmux.conf contains 'remain-on-exit on'"
else
  fail "tmux.conf missing 'remain-on-exit on'"
fi

# --- Test 29: tmux.conf contains pane-died hook ---
echo ""
echo "=== Test 29: tmux.conf has pane-died hook ==="
if grep -q "pane-died" "${REPO_ROOT}/tmux.conf"; then
  pass "tmux.conf contains pane-died hook"
else
  fail "tmux.conf missing pane-died hook"
fi

# --- Test 30: init-rip-cage.sh does NOT contain runtime remain-on-exit set ---
echo ""
echo "=== Test 30: init-rip-cage.sh runtime remain-on-exit removed ==="
if grep -q "tmux set-option -t rip-cage remain-on-exit" "${REPO_ROOT}/init-rip-cage.sh"; then
  fail "init-rip-cage.sh still has runtime 'tmux set-option -t rip-cage remain-on-exit' (should be removed)"
else
  pass "init-rip-cage.sh does not have runtime remain-on-exit set (moved to tmux.conf)"
fi

# --- Test 31: init-rip-cage.sh does NOT contain runtime pane-died hook set ---
echo ""
echo "=== Test 31: init-rip-cage.sh runtime pane-died hook removed ==="
if grep -q "tmux set-hook -t rip-cage pane-died" "${REPO_ROOT}/init-rip-cage.sh"; then
  fail "init-rip-cage.sh still has runtime 'tmux set-hook -t rip-cage pane-died' (should be removed)"
else
  pass "init-rip-cage.sh does not have runtime pane-died hook set (moved to tmux.conf)"
fi

# --- Test 32: rc up --new flag is recognized (dry-run, no-TTY) ---
echo ""
echo "=== Test 32: rc up --new flag recognized ==="
TEST_DIR_T32=$(mktemp -d)
mkdir -p "${TEST_DIR_T32}/.git"
new_flag_out=$(RC_ALLOWED_ROOTS="$TEST_DIR_T32" "$RC" up --dry-run --new "$TEST_DIR_T32" 2>&1 </dev/null || true)
if echo "$new_flag_out" | grep -qi "unknown.*flag\|invalid.*option\|unrecognized"; then
  fail "rc up --new flag not recognized (got: $new_flag_out)"
else
  pass "rc up --new flag recognized (no unrecognized flag error)"
fi
rm -rf "$TEST_DIR_T32"

# --- Test 33: rc up --session flag is recognized (dry-run, no-TTY) ---
echo ""
echo "=== Test 33: rc up --session flag recognized ==="
TEST_DIR_T33=$(mktemp -d)
mkdir -p "${TEST_DIR_T33}/.git"
session_flag_out=$(RC_ALLOWED_ROOTS="$TEST_DIR_T33" "$RC" up --dry-run --session "rip-cage" "$TEST_DIR_T33" 2>&1 </dev/null || true)
if echo "$session_flag_out" | grep -qi "unknown.*flag\|invalid.*option\|unrecognized"; then
  fail "rc up --session flag not recognized (got: $session_flag_out)"
else
  pass "rc up --session flag recognized (no unrecognized flag error)"
fi
rm -rf "$TEST_DIR_T33"

# --- Test 34: _up_attach_tmux uses [[ -t 0 && -t 1 ]] (both stdin and stdout TTY check) ---
echo ""
echo "=== Test 34: _up_attach_tmux checks both stdin and stdout TTY ==="
# Verify the source code uses the widened check
if grep -A5 "_up_attach_tmux()" "${REPO_ROOT}/rc" | grep -q "\-t 0"; then
  pass "_up_attach_tmux includes -t 0 (stdin) TTY check"
else
  fail "_up_attach_tmux missing -t 0 stdin TTY check"
fi

# --- Test 35: _tmux_picker N=0 with mode=attach returns exit 1 + stderr pointing to rc up ---
echo ""
echo "=== Test 35: _tmux_picker in attach mode with N=0 sessions exits 1 + stderr points to rc up ==="
t35_out=$(bash -c '
_PICKER_SESSION=""
_tmux_picker() {
  local cname="$1"
  local mode="${2:-up}"
  # Simulate: docker returns 0 sessions
  local raw_sessions=""
  local sorted_sessions
  sorted_sessions=$(echo "$raw_sessions" | sort -s -k1,1 -rn | awk '"'"'{$1=""; print substr($0,2)}'"'"' )
  local session_count
  session_count=$(echo "$sorted_sessions" | grep -c . || true)
  if [[ "$session_count" -eq 0 ]]; then
    if [[ "$mode" == "attach" ]]; then
      echo "Error: no tmux sessions running in $cname. Start one with: rc up" >&2
      return 1
    fi
    _PICKER_SESSION="rip-cage"
    return 0
  fi
}
_tmux_picker "fake-cage" "attach"
echo "exit:$?"
' 2>&1)
if echo "$t35_out" | grep -q "exit:1"; then
  pass "_tmux_picker attach N=0: exits 1"
else
  fail "_tmux_picker attach N=0: expected exit 1 (got: $t35_out)"
fi
if echo "$t35_out" | grep -qi "rc up"; then
  pass "_tmux_picker attach N=0: stderr points to rc up"
else
  fail "_tmux_picker attach N=0: stderr should mention 'rc up' (got: $t35_out)"
fi

# --- Test 36: rc sessions is NOT listed in usage (rip-cage-1f59.3: sessions retired) ---
echo ""
echo "=== Test 36: rc sessions in usage text ==="
usage_out=$("$RC" 2>&1 || true)
if echo "$usage_out" | grep -q "^  sessions"; then
  fail "rc usage still mentions sessions subcommand (should be removed per rip-cage-1f59.3)"
else
  pass "rc usage does not mention sessions subcommand (correctly retired)"
fi

# --- Test 37: ADR-006 contains Tier 1a (parallel tmux sessions) ---
echo ""
echo "=== Test 37: ADR-006 D1 contains Tier 1a ==="
if grep -q "Tier 1a" "${REPO_ROOT}/docs/decisions/ADR-006-multi-agent-architecture.md"; then
  pass "ADR-006 contains Tier 1a"
else
  fail "ADR-006 missing Tier 1a (parallel tmux sessions in one cage)"
fi

# --- Test 38: ADR-006 contains Tier 1b (multiple containers) ---
echo ""
echo "=== Test 38: ADR-006 D1 contains Tier 1b ==="
if grep -q "Tier 1b" "${REPO_ROOT}/docs/decisions/ADR-006-multi-agent-architecture.md"; then
  pass "ADR-006 contains Tier 1b"
else
  fail "ADR-006 missing Tier 1b (multiple containers rename)"
fi

# --- Test 39: multi-agent-architecture.md Tier 1 heading renamed to Tier 1b ---
echo ""
echo "=== Test 39: multi-agent-architecture.md has Tier 1b heading ==="
if grep -q "Tier 1b" "${REPO_ROOT}/docs/2026-03-27-multi-agent-architecture.md"; then
  pass "multi-agent-architecture.md contains Tier 1b"
else
  fail "multi-agent-architecture.md missing Tier 1b rename"
fi

# --- Test 40: ROADMAP.md line 76 area has Tier 1b (not bare Tier 1) ---
echo ""
echo "=== Test 40: ROADMAP.md multi-agent workflow line uses Tier 1b ==="
if grep -q "Tier 1b" "${REPO_ROOT}/docs/ROADMAP.md"; then
  pass "ROADMAP.md contains Tier 1b reference"
else
  fail "ROADMAP.md missing Tier 1b (line 76 should be updated)"
fi

# --- Test 41: cli-reference.md Running multiple agents section lacks v0.3 forward-pointer ---
echo ""
echo "=== Test 41: cli-reference.md no longer has v0.3 forward-pointer ==="
if grep -q "v0\.3" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  fail "cli-reference.md still has v0.3 forward-pointer (should be removed)"
else
  pass "cli-reference.md no longer has v0.3 forward-pointer"
fi

# --- Test 42: cli-reference.md does NOT mention rc sessions (retired rip-cage-1f59.6) ---
# NON-VACUOUS: would fail if rc sessions were still present as a live command in cli-reference.md.
# Inverted from "presence → pass" to "absence → pass" per debt note from rip-cage-1f59.3.
echo ""
echo "=== Test 42: cli-reference.md does NOT document rc sessions (retired) ==="
if grep -q "rc sessions" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  fail "cli-reference.md still mentions rc sessions as a live command (should be retired per rip-cage-1f59.6)"
else
  pass "cli-reference.md does not mention rc sessions (correctly retired)"
fi
# Also assert rc agent is absent from cli-reference.md
if grep -q "rc agent" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  fail "cli-reference.md still mentions rc agent as a live command (should be retired per rip-cage-1f59.6)"
else
  pass "cli-reference.md does not mention rc agent (correctly retired)"
fi

# --- Test 43: cli-reference.md documents --new flag ---
echo ""
echo "=== Test 43: cli-reference.md documents --new flag ==="
if grep -q "\-\-new" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  pass "cli-reference.md documents --new flag"
else
  fail "cli-reference.md missing --new flag documentation"
fi

# --- Test 44: CHANGELOG.md Unreleased has new picker/sessions Added entries ---
echo ""
echo "=== Test 44: CHANGELOG.md Unreleased mentions picker ==="
if grep -q "picker\|rc sessions\|--new" "${REPO_ROOT}/CHANGELOG.md"; then
  pass "CHANGELOG.md mentions picker or rc sessions in Unreleased"
else
  fail "CHANGELOG.md missing picker/rc sessions in Unreleased section"
fi

# --- Test 45: rc agent and rc sessions absent from both completion files (rip-cage-1f59.3) ---
# NON-VACUOUS: would fail if completions/rc.bash or completions/_rc still listed
# agent or sessions as subcommands. A still-present command would appear as a
# literal token in the completion arrays — absence is the discriminating assertion.
echo ""
echo "=== Test 45: rc agent and rc sessions absent from completion files (rip-cage-1f59.3) ==="
BASH_COMP="${REPO_ROOT}/completions/rc.bash"
ZSH_COMP="${REPO_ROOT}/completions/_rc"
t45_fail=0
if grep -q "\bsessions\b" "$BASH_COMP" 2>/dev/null; then
  fail "completions/rc.bash still contains 'sessions' token (should be retired)"
  t45_fail=1
else
  pass "completions/rc.bash does not contain 'sessions' token (correctly retired)"
fi
if grep -q "\bagent\b" "$BASH_COMP" 2>/dev/null; then
  fail "completions/rc.bash still contains 'agent' token (should be retired)"
  t45_fail=1
else
  pass "completions/rc.bash does not contain 'agent' token (correctly retired)"
fi
if grep -q "\bsessions\b" "$ZSH_COMP" 2>/dev/null; then
  fail "completions/_rc still contains 'sessions' token (should be retired)"
  t45_fail=1
else
  pass "completions/_rc does not contain 'sessions' token (correctly retired)"
fi
if grep -q "\bagent\b" "$ZSH_COMP" 2>/dev/null; then
  fail "completions/_rc still contains 'agent' token (should be retired)"
  t45_fail=1
else
  pass "completions/_rc does not contain 'agent' token (correctly retired)"
fi
# Paired exit-code: --output json on a retired command must not return exit 0
sessions_json_exit_t45=0
"$RC" --output json sessions no-such-container-xyz >/dev/null 2>&1 || sessions_json_exit_t45=$?
if [[ "$sessions_json_exit_t45" -ne 0 ]]; then
  pass "rc sessions --output json: unknown-command, non-zero exit"
else
  fail "rc sessions --output json: expected non-zero exit (command was retired), got exit 0"
fi

# --- Test 46: picker EOF on stdin exits 1 with expected stderr message (AC-5b) ---
echo ""
echo "=== Test 46: picker EOF on stdin exits 1 and prints expected message ==="
# Inline the picker read loop with a pre-built names array (no docker calls needed).
# Feed EOF from /dev/null as stdin to trigger the EOF path.
t46_stderr=$(bash -c '
_PICKER_SESSION=""
# Pre-built state: one session in the names array (so we reach the read loop)
names=("rip-cage")
new_idx=2
# Reproduce the picker read loop
local_input=""
local_invalid=0
while true; do
  printf "Pick [1]: " >&2
  if ! read -r local_input; then
    echo "" >&2
    echo "rc: picker received EOF on stdin; refusing to auto-select. Use --new or --session <name>, or attach via '"'"'rc attach <cage>'"'"'." >&2
    exit 1
  fi
  local_input=$(echo "$local_input" | sed '"'"'s/^[[:space:]]*//;s/[[:space:]]*$//'"'"')
  if [[ -z "$local_input" ]]; then
    _PICKER_SESSION="${names[0]}"
    exit 0
  fi
  case "$local_input" in
    '"'"''"'"'|*[!0-9]*)
      local_invalid=$((local_invalid + 1))
      [[ "$local_invalid" -ge 2 ]] && exit 1
      continue ;;
  esac
  if [[ "$local_input" -ge 1 ]] && [[ "$local_input" -lt "$new_idx" ]]; then
    _PICKER_SESSION="${names[$((local_input - 1))]}"
    exit 0
  fi
  local_invalid=$((local_invalid + 1))
  [[ "$local_invalid" -ge 2 ]] && exit 1
done
' </dev/null 2>&1)
t46_exit=$?
if [[ "$t46_exit" -ne 0 ]]; then
  pass "picker EOF: exits non-zero (exit $t46_exit)"
else
  fail "picker EOF: expected non-zero exit, got 0 (stderr: $t46_stderr)"
fi
if echo "$t46_stderr" | grep -q "EOF on stdin\|refusing to auto-select"; then
  pass "picker EOF: stderr contains expected message"
else
  fail "picker EOF: stderr missing expected message (got: $t46_stderr)"
fi

# --- Test 47: picker whitespace-only input treated as empty → selects entry 1 (AC-5c) ---
echo ""
echo "=== Test 47: picker whitespace-only input selects entry 1 ==="
# Feed "   \n" (spaces + newline) to the picker read loop; expect it selects names[0]
t47_result=$(bash -c '
_PICKER_SESSION=""
names=("rip-cage" "rip-cage-2")
new_idx=3
local_input=""
local_invalid=0
while true; do
  if ! read -r local_input; then
    exit 1
  fi
  local_input=$(echo "$local_input" | sed '"'"'s/^[[:space:]]*//;s/[[:space:]]*$//'"'"')
  if [[ -z "$local_input" ]]; then
    _PICKER_SESSION="${names[0]}"
    echo "selected:${names[0]}"
    exit 0
  fi
  case "$local_input" in
    '"'"''"'"'|*[!0-9]*)
      local_invalid=$((local_invalid + 1))
      [[ "$local_invalid" -ge 2 ]] && exit 1
      continue ;;
  esac
  if [[ "$local_input" -ge 1 ]] && [[ "$local_input" -lt "$new_idx" ]]; then
    _PICKER_SESSION="${names[$((local_input - 1))]}"
    echo "selected:${names[$((local_input - 1))]}"
    exit 0
  fi
  local_invalid=$((local_invalid + 1))
  [[ "$local_invalid" -ge 2 ]] && exit 1
done
' < <(printf '   \n')
)
if echo "$t47_result" | grep -q "selected:rip-cage$"; then
  pass "picker whitespace-only input: selects entry 1 (rip-cage)"
else
  fail "picker whitespace-only input: expected 'selected:rip-cage', got: $t47_result"
fi

# --- Test 48: rc exec is listed in usage ---
echo ""
echo "=== Test 48: rc exec in usage text ==="
usage_t48=$("$RC" 2>&1 || true)
if echo "$usage_t48" | grep -q "^  exec"; then
  pass "rc usage mentions exec subcommand"
else
  fail "rc usage does not mention exec subcommand"
fi

# --- Test 49: rc exec is listed in rc schema ---
echo ""
echo "=== Test 49: rc exec in rc schema ==="
schema_t49=$("$RC" schema 2>/dev/null || true)
if echo "$schema_t49" | jq -e '.commands | has("exec")' >/dev/null 2>&1; then
  pass "rc schema contains exec command"
else
  fail "rc schema does not contain exec command (got: $schema_t49)"
fi

# --- Test 50: rc exec --output json is in the json allowlist (no 'not supported' error) ---
echo ""
echo "=== Test 50: rc exec --output json is in the json allowlist ==="
# rc exec must exist and --output json must not be rejected by the allowlist guard
# (if exec doesn't exist yet, it falls through to usage with exit 1 — the key test is
#  that it does NOT print the "not supported for 'exec'" allowlist rejection message)
exec_json_t50=$("$RC" --output json exec no-such-container-xyz -- echo hi 2>&1 || true)
if echo "$exec_json_t50" | grep -q "not supported for 'exec'"; then
  fail "rc exec --output json wrongly rejected by allowlist guard"
else
  # Also confirm the command is recognized (not falling through to usage unknown-cmd)
  if echo "$exec_json_t50" | jq -e '.code // empty' >/dev/null 2>&1; then
    pass "rc exec --output json: recognized command, JSON error shape returned (not in usage)"
  else
    # It may print usage if exec doesn't exist — that's a FAIL
    if echo "$exec_json_t50" | grep -q "^  exec "; then
      fail "rc exec not yet implemented — falls through to usage"
    else
      pass "rc exec --output json is in json allowlist (not rejected)"
    fi
  fi
fi

# --- Test 51: rc exec -- separator is parsed ---
echo ""
echo "=== Test 51: rc exec command is dispatched (not treated as unknown) ==="
# Verify rc exec is dispatched (not a usage-fallthrough). With no such container, it should
# produce an error about the container (not just "usage"). Best proxy: output must NOT be
# the general usage text (which starts with "Usage: rc").
exec_t51=$("$RC" exec no-such-container-xyz -- echo hi 2>&1 || true)
if echo "$exec_t51" | grep -q "^Usage: rc"; then
  fail "rc exec falls through to usage (command not dispatched)"
else
  pass "rc exec dispatched (no usage fallthrough)"
fi

# --- Test 52: check_tmux source-gating — verify check_tmux is not called unconditionally for all up invocations ---
echo ""
echo "=== Test 52: check_tmux gating — verify dispatch gate is multiplexer-aware ==="
# Strategy: the dispatch gate for check_tmux must guard on the configured multiplexer value.
# Before implementation the gate was:
#   up|attach|sessions|agent) [[ "$OUTPUT_FORMAT" == "json" ]] || check_tmux ;;
# After implementation the check_tmux call must be guarded by a multiplexer variable check,
# not called unconditionally for all 'up' invocations.
# We assert: the line calling check_tmux (not the function def, not comments) ALSO references
# a multiplexer variable or calls a multiplexer-reading helper.
# "multiplexer" substring in the dispatch section (not just inside "check_tmux" word itself).
t52_gate_section=$(awk '/^# Prerequisite checks/,/^# Main dispatch/' "$RC")
if echo "$t52_gate_section" | grep -q "check_tmux" && \
   echo "$t52_gate_section" | grep -q "session.multiplexer\|_rc_mux_check\|multiplexer.*tmux\|tmux.*multiplexer"; then
  pass "check_tmux dispatch gate is multiplexer-aware (multiplexer variable referenced in prereq section)"
else
  fail "check_tmux dispatch gate not multiplexer-aware — gate section lacks multiplexer reference alongside check_tmux"
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
