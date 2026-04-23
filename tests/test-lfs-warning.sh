#!/usr/bin/env bash
# Tests for the LFS pointer-stub detection/warning path in `rc`.
# Pure host-side check (no docker required) — exercised via `rc up --dry-run`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker > /dev/null 2>&1; then
  # Dry-run still needs docker image check to short-circuit; but the LFS
  # warning fires *before* any docker call, so this test is docker-free.
  :
fi

# LFS pointer file content (standard v1 pointer — matches real git-lfs stubs)
LFS_POINTER_CONTENT="version https://git-lfs.github.com/spec/v1
oid sha256:deadbeefcafebabe0123456789abcdef0123456789abcdef0123456789abcdef
size 42"

make_lfs_repo() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/.gitattributes" <<'EOF'
*.parquet filter=lfs diff=lfs merge=lfs -text
EOF
  printf '%s\n' "$LFS_POINTER_CONTENT" > "$dir/fixture.parquet"
}

run_rc_up_dry() {
  # Run `rc up --dry-run` and capture stderr. Use RC_ALLOWED_ROOTS so validate_path
  # doesn't TTY-prompt. Tolerate non-zero exit (image-build path); we only want stderr.
  local dir="$1"
  local parent
  parent=$(dirname "$dir")
  { RC_ALLOWED_ROOTS="$parent" "$RC" --dry-run up "$dir" >/dev/null; } 2>&1 || true
}

# --- Test 1: LFS repo with stub file → warning fires ---
echo "=== Test 1: LFS repo with pointer stub warns ==="
TEST_DIR=$(mktemp -d)
make_lfs_repo "$TEST_DIR"
out=$(run_rc_up_dry "$TEST_DIR")
if echo "$out" | grep -q "LFS pointer stubs detected"; then
  pass "warning header present"
else
  fail "warning header missing; output was: $out"
fi
if echo "$out" | grep -Eq 'git -C .* lfs pull'; then
  pass "warning includes host-side command hint"
else
  fail "warning missing host-side command hint"
fi
if echo "$out" | grep -q "fixture.parquet"; then
  pass "warning lists stub path"
else
  fail "warning does not list stub path"
fi
rm -rf "$TEST_DIR"

# --- Test 2: LFS repo with materialized (large, non-stub) file → no warning ---
echo ""
echo "=== Test 2: LFS repo with materialized blob emits no warning ==="
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR"
cat > "$TEST_DIR/.gitattributes" <<'EOF'
*.parquet filter=lfs diff=lfs merge=lfs -text
EOF
# Non-stub file: >200 bytes and no LFS pointer header
head -c 1024 /dev/urandom > "$TEST_DIR/fixture.parquet"
out=$(run_rc_up_dry "$TEST_DIR")
if echo "$out" | grep -q "LFS pointer stubs detected"; then
  fail "warning fired for materialized repo; output: $out"
else
  pass "no warning for materialized blob"
fi
rm -rf "$TEST_DIR"

# --- Test 3: non-LFS repo (no .gitattributes filter=lfs) → no warning ---
echo ""
echo "=== Test 3: non-LFS repo emits no warning ==="
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR"
echo "hello" > "$TEST_DIR/readme.md"
out=$(run_rc_up_dry "$TEST_DIR")
if echo "$out" | grep -q "LFS pointer stubs detected"; then
  fail "warning fired for non-LFS repo; output: $out"
else
  pass "no warning for non-LFS repo"
fi
rm -rf "$TEST_DIR"

# --- Test 4: small non-LFS files in repo without filter=lfs → no false positive ---
echo ""
echo "=== Test 4: repo with small non-LFS files emits no warning ==="
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR"
echo "not-an-lfs-pointer" > "$TEST_DIR/small1.txt"
echo "also-not-lfs" > "$TEST_DIR/small2.txt"
out=$(run_rc_up_dry "$TEST_DIR")
if echo "$out" | grep -q "LFS pointer stubs detected"; then
  fail "false positive on small non-LFS files; output: $out"
else
  pass "no false positive on small non-LFS files"
fi
rm -rf "$TEST_DIR"

# --- Test 5: regression — LFS gitattributes + no stubs must NOT kill rc up ---
# Regression for the silent-exit-1 bug where `find -exec grep -l` returning 1
# (no match) propagated through `pipefail` and killed `rc up` under `set -e`
# before the container was created. Symptom: `rc up` exits 1 with no output
# in any repo that declares filter=lfs but has no pointer stubs.
echo ""
echo "=== Test 5: rc up --dry-run exits 0 on LFS repo with no stubs ==="
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR"
cat > "$TEST_DIR/.gitattributes" <<'EOF'
*.parquet filter=lfs diff=lfs merge=lfs -text
EOF
# Small non-stub files: must exercise the find/grep-l inner branch.
echo "not-an-lfs-pointer" > "$TEST_DIR/small1.txt"
echo "also-not-lfs" > "$TEST_DIR/small2.txt"
parent=$(dirname "$TEST_DIR")
RC_ALLOWED_ROOTS="$parent" "$RC" --dry-run up "$TEST_DIR" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "rc up --dry-run exited 0"
else
  fail "rc up --dry-run exited $rc (expected 0) — silent-exit regression"
fi
rm -rf "$TEST_DIR"

echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo "All LFS warning tests passed."
  exit 0
else
  echo "FAILED: $FAILURES test(s) failed."
  exit 1
fi
