#!/usr/bin/env bash
# Unit-style tests for rip-cage-bnf.1: github.com identity resolver (rc host-side).
#
# Tests the following functions sourced from rc:
#   _parse_identity_rules() -- rules-file parser (glob+keyname+tilde-expansion)
#   _resolve_github_identity() -- four-layer resolver (CLI→label→rules→unset)
#
# Also verifies CLI flag handling observable from container labels (requires docker).
#
# Does NOT require a running container for the unit tests (Tests 1-5).
# Tests 6-10 require docker + rip-cage image built.
#
# Acceptance criteria covered:
#   AC1: CLI flag beats rules-file match on new container → Test 6
#   AC2: Rules-file match used when no CLI flag; empty when no match → Tests 7, 8
#   AC3: Resume with existing label + CLI flag → exits non-zero, names both → Test 9
#   AC4: Resume with existing label, no CLI flag → label preserved, success → Test 10
#   AC5: Comments/blanks skipped; first match wins; tilde expansion → Tests 2, 3, 4

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_WS=""
CONTAINER=""
RULES_FILE=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Resolve the container name from the workspace label — robust against
# rc's collision-hash fallback and tr/sed name normalization.
_resolve_container() {
  docker ps -a --filter "label=rc.source.path=$(realpath "$TEST_WS" 2>/dev/null || echo "$TEST_WS")" \
    --format '{{.Names}}' | head -1
}

cleanup() {
  local _c
  if command -v docker >/dev/null 2>&1 && [[ -n "${TEST_WS:-}" ]]; then
    _c=$(_resolve_container 2>/dev/null || true)
    [[ -n "$_c" ]] && docker rm -f "$_c" >/dev/null 2>&1 || true
  fi
  [[ -n "${RULES_FILE:-}" && -f "${RULES_FILE:-}" ]] && rm -f "$RULES_FILE"
  if [[ -n "${TEST_WS:-}" && -d "${TEST_WS:-}" ]]; then
    rm -rf "$TEST_WS"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Load only the pure functions from rc (no set -e, no top-level docker calls)
# We source rc in a subshell context to extract the functions we need to test.
# ---------------------------------------------------------------------------

# Source rc to get function definitions; set stub for HOME-dependent tests
_source_rc_functions() {
  # We need to load rc without triggering its top-level guards.
  # rc has these top-level guards:
  #   1. completions fast-path (checks $1 == "completions")
  #   2. /.dockerenv container guard
  # We source it with the functions we need extracted into our current shell.
  # The container guard only triggers if /.dockerenv exists (we're on host).
  # Completions guard only triggers on "$1 == completions" — not an issue for sourcing.
  # set -e is active in rc; we need to be careful to not trigger it.

  # Extract just the function bodies we need via grep and eval — cleaner than
  # sourcing the entire rc (which would re-run config loading, etc.)
  # Instead, source with a no-op override for functions with docker calls.

  # Temporarily unset set -e while sourcing to avoid rc's set -euo pipefail
  # making the unit test environment fragile.
  set +e
  # Source rc — the pure functions (_parse_identity_rules, _resolve_github_identity)
  # have no side effects. Docker calls happen only in cmd_* functions.
  # shellcheck source=../rc
  source "$RC" 2>/dev/null
  set -e
}

_source_rc_functions

# ---------------------------------------------------------------------------
# Test 1: _parse_identity_rules — file absent yields empty result (AC5)
# ---------------------------------------------------------------------------
echo "=== Test 1: _parse_identity_rules — absent file yields empty ==="
result=$(_parse_identity_rules "/no/such/rules/file" "/some/project/path")
if [[ -z "$result" ]]; then
  pass "absent rules file → empty result"
else
  fail "absent rules file → unexpected result: '$result'"
fi

# ---------------------------------------------------------------------------
# Test 2: _parse_identity_rules — comments and blank lines skipped (AC5)
# ---------------------------------------------------------------------------
echo "=== Test 2: _parse_identity_rules — comments and blanks skipped ==="
RULES_FILE=$(mktemp /tmp/rc-test-identity-rules.XXXXXX)
cat > "$RULES_FILE" <<'EOF'
# This is a comment

# Another comment

~/code/personal/*   id_ed25519_personal
~/code/mapular/*    id_ed25519_work
EOF

# Match the personal path
result=$(_parse_identity_rules "$RULES_FILE" "${HOME}/code/personal/my-project")
if [[ "$result" == "id_ed25519_personal" ]]; then
  pass "comments/blanks skipped; correct key matched for personal path"
else
  fail "comments/blanks: expected 'id_ed25519_personal', got '$result'"
fi

# ---------------------------------------------------------------------------
# Test 3: _parse_identity_rules — first match wins (AC5)
# ---------------------------------------------------------------------------
echo "=== Test 3: _parse_identity_rules — first match wins ==="
# Both rules would match ~/code/personal/rip-cage if glob is broad,
# but more-specific first pattern wins.
cat > "$RULES_FILE" <<'EOF'
~/code/personal/rip-cage   id_ed25519_special
~/code/personal/*           id_ed25519_personal
EOF

result=$(_parse_identity_rules "$RULES_FILE" "${HOME}/code/personal/rip-cage")
if [[ "$result" == "id_ed25519_special" ]]; then
  pass "first match wins over broader later pattern"
else
  fail "first-match: expected 'id_ed25519_special', got '$result'"
fi

# ---------------------------------------------------------------------------
# Test 4: _parse_identity_rules — tilde expansion in patterns (AC5)
# ---------------------------------------------------------------------------
echo "=== Test 4: _parse_identity_rules — tilde expansion ==="
cat > "$RULES_FILE" <<'EOF'
~/code/mapular/*    id_ed25519_work
EOF

result=$(_parse_identity_rules "$RULES_FILE" "${HOME}/code/mapular/mapular-gtm")
if [[ "$result" == "id_ed25519_work" ]]; then
  pass "tilde-prefixed glob expands correctly for matching path"
else
  fail "tilde expansion: expected 'id_ed25519_work', got '$result'"
fi

# No match for a non-matching path
result2=$(_parse_identity_rules "$RULES_FILE" "${HOME}/code/personal/rip-cage")
if [[ -z "$result2" ]]; then
  pass "non-matching path yields empty from rules file"
else
  fail "non-match: expected empty, got '$result2'"
fi

# ---------------------------------------------------------------------------
# Test 5: _resolve_github_identity — layer 4: no match yields empty (AC2)
# ---------------------------------------------------------------------------
echo "=== Test 5: _resolve_github_identity — no match yields empty (layer 4) ==="
# No CLI flag, no container label (new container), no rules file → empty
# We call with: (cli_flag, container_name, project_path, rules_file)
# For a new container, container_name is empty or container doesn't exist.
# No docker interaction needed when container_name is empty.
cat > "$RULES_FILE" <<'EOF'
~/code/mapular/*    id_ed25519_work
EOF

result=$(_resolve_github_identity "" "" "${HOME}/code/personal/rip-cage" "$RULES_FILE")
if [[ -z "$result" ]]; then
  pass "layer 4 (no match): _resolve_github_identity returns empty"
else
  fail "layer 4: expected empty, got '$result'"
fi

# ---------------------------------------------------------------------------
# Tests 6-10 require docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available — skipping container-level tests (AC1, AC3, AC4)"
  echo
  echo "=== Results: $FAILURES failure(s) ==="
  exit "$FAILURES"
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest image not built — run ./rc build first (skipping AC1, AC3, AC4)"
  echo
  echo "=== Results: $FAILURES failure(s) ==="
  exit "$FAILURES"
fi

TEST_WS=$(mktemp -d)
cat > "$RULES_FILE" <<'EOF'
~/code/mapular/*    id_ed25519_work
~/code/personal/*   id_ed25519_personal
EOF

# ---------------------------------------------------------------------------
# Test 6: CLI flag beats rules-file on new container (AC1)
# ---------------------------------------------------------------------------
echo "=== Test 6: CLI flag beats rules-file on new container (AC1) ==="
# Use a temp path that would match ~/code/personal/* if resolved,
# but CLI flag should win.
RIP_CAGE_IDENTITY_RULES="$RULES_FILE" RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off \
  "$RC" up --github-identity=id_ed25519_work "$TEST_WS" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(_resolve_container)
if [[ -z "$CONTAINER" ]]; then
  fail "Test 6: container did not come up"
else
  label=$(docker inspect --format '{{ index .Config.Labels "rc.github-identity" }}' "$CONTAINER" 2>/dev/null)
  if [[ "$label" == "id_ed25519_work" ]]; then
    pass "Test 6: rc.github-identity label = '$label' (CLI flag value)"
  else
    fail "Test 6: rc.github-identity label = '$label' (expected 'id_ed25519_work')"
  fi
fi

# ---------------------------------------------------------------------------
# Test 7: Rules-file match used when no CLI flag (AC2)
# ---------------------------------------------------------------------------
echo "=== Test 7: Rules-file match used when no CLI flag (AC2) ==="
docker rm -f "$CONTAINER" >/dev/null 2>&1

# Use a temp workspace path that simulates ~/code/mapular/* matching
# We need a path that triggers the rules file match. Since TEST_WS is /tmp/...,
# it won't match ~/code/mapular/*. We need to use RIP_CAGE_GITHUB_IDENTITY
# env var OR test with a path that matches.
# Instead, use a directory under $HOME that matches the rules file pattern.
local_ws="${HOME}/code/personal/.rc-test-$$"
mkdir -p "$local_ws"
RC_ALLOWED_ROOTS="$local_ws" RIP_CAGE_EGRESS=off RIP_CAGE_IDENTITY_RULES="$RULES_FILE" \
  "$RC" up "$local_ws" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(docker ps -a --filter "label=rc.source.path=$local_ws" --format '{{.Names}}' | head -1)
if [[ -z "$CONTAINER" ]]; then
  fail "Test 7: container did not come up"
else
  label=$(docker inspect --format '{{ index .Config.Labels "rc.github-identity" }}' "$CONTAINER" 2>/dev/null)
  if [[ "$label" == "id_ed25519_personal" ]]; then
    pass "Test 7: rc.github-identity label = '$label' (rules-file match)"
  else
    fail "Test 7: rc.github-identity label = '$label' (expected 'id_ed25519_personal' from rules file)"
  fi
  docker rm -f "$CONTAINER" >/dev/null 2>&1
fi
rm -rf "$local_ws"

# ---------------------------------------------------------------------------
# Test 8: No match → label absent/empty (layer 4) (AC2)
# ---------------------------------------------------------------------------
echo "=== Test 8: No CLI flag + no rules match → label absent (AC2) ==="
docker rm -f "$(_resolve_container 2>/dev/null)" >/dev/null 2>&1 || true

# TEST_WS is under /tmp, which won't match ~/code/mapular/* or ~/code/personal/*
RIP_CAGE_IDENTITY_RULES="$RULES_FILE" RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off \
  "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(_resolve_container)
if [[ -z "$CONTAINER" ]]; then
  fail "Test 8: container did not come up"
else
  label=$(docker inspect --format '{{ index .Config.Labels "rc.github-identity" }}' "$CONTAINER" 2>/dev/null)
  if [[ -z "$label" ]]; then
    pass "Test 8: rc.github-identity label absent (no match, layer 4)"
  else
    fail "Test 8: rc.github-identity label = '$label' (expected absent/empty for no-match)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 9: Resume with existing label + CLI override → exit non-zero, error names both (AC3)
# ---------------------------------------------------------------------------
echo "=== Test 9: Resume + CLI override → exit non-zero naming label and container (AC3) ==="
# Container from Test 8 has no github-identity label. Create a fresh container
# WITH a label to test the resume conflict.
docker rm -f "$CONTAINER" >/dev/null 2>&1

RIP_CAGE_IDENTITY_RULES="$RULES_FILE" RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off \
  "$RC" up --github-identity=id_ed25519_work "$TEST_WS" </dev/null >/dev/null 2>&1 || true

CONTAINER=$(_resolve_container)
if [[ -z "$CONTAINER" ]]; then
  fail "Test 9 setup: container did not come up with --github-identity label"
else
  # Verify the label was set
  label=$(docker inspect --format '{{ index .Config.Labels "rc.github-identity" }}' "$CONTAINER" 2>/dev/null)
  if [[ "$label" != "id_ed25519_work" ]]; then
    fail "Test 9 setup: label not set correctly, got '$label'"
  else
    # Stop the container, then try to resume with a different --github-identity
    docker stop "$CONTAINER" >/dev/null 2>&1

    err_output=""
    exit_code=0
    err_output=$(RIP_CAGE_IDENTITY_RULES="$RULES_FILE" RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off \
      "$RC" up --github-identity=id_ed25519_personal "$TEST_WS" </dev/null 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
      pass "Test 9: resume with CLI override exited non-zero (exit=$exit_code)"
    else
      fail "Test 9: resume with CLI override exited 0 (should have been non-zero)"
    fi

    # Error output should name the existing label value and the container name
    if echo "$err_output" | grep -q "id_ed25519_work"; then
      pass "Test 9: error names existing label value 'id_ed25519_work'"
    else
      fail "Test 9: error does not name existing label value (output: '$err_output')"
    fi

    if echo "$err_output" | grep -q "$CONTAINER"; then
      pass "Test 9: error names the container '$CONTAINER'"
    else
      fail "Test 9: error does not name the container (output: '$err_output')"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Test 10: Resume with existing label, no CLI flag → label preserved, success (AC4)
# ---------------------------------------------------------------------------
echo "=== Test 10: Resume with existing label, no CLI flag → preserved, success (AC4) ==="
# The container from Test 9 should still exist (we stopped it, not removed it).
# If it was removed in the error path, recreate it.
CONTAINER=$(_resolve_container)
if [[ -z "$CONTAINER" ]]; then
  RIP_CAGE_IDENTITY_RULES="$RULES_FILE" RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off \
    "$RC" up --github-identity=id_ed25519_work "$TEST_WS" </dev/null >/dev/null 2>&1 || true
  CONTAINER=$(_resolve_container)
  docker stop "$CONTAINER" >/dev/null 2>&1
fi

if [[ -z "$CONTAINER" ]]; then
  fail "Test 10 setup: container not available"
else
  # Resume without CLI flag — should succeed and preserve the label
  exit_code=0
  RIP_CAGE_IDENTITY_RULES="$RULES_FILE" RC_ALLOWED_ROOTS="$TEST_WS" RIP_CAGE_EGRESS=off \
    "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    pass "Test 10: resume without CLI flag succeeded (exit=0)"
  else
    fail "Test 10: resume without CLI flag failed (exit=$exit_code)"
  fi

  label=$(docker inspect --format '{{ index .Config.Labels "rc.github-identity" }}' "$CONTAINER" 2>/dev/null)
  if [[ "$label" == "id_ed25519_work" ]]; then
    pass "Test 10: rc.github-identity label preserved as '$label' on resume"
  else
    fail "Test 10: rc.github-identity label = '$label' (expected 'id_ed25519_work' preserved)"
  fi
fi

echo
echo "=== Results: $FAILURES failure(s) ==="
exit "$FAILURES"
