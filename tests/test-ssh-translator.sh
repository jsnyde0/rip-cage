#!/usr/bin/env bash
# Unit-style tests for rip-cage-bnf.2: host-config translation engine.
#
# Tests the _translate_ssh_config() function sourced from rc.
#
# Acceptance criteria covered:
#   AC1: full fixture → IgnoreUnknown leads, paths rewritten, in-home Include inlined,
#        out-of-home Include stripped, no host-absolute paths outside comments
#   AC2: host-only directives stripped, ADR-014 D2 directives overridden with annotation
#   AC3: pin set + no Host github.com → synth block with IdentitiesOnly yes;
#        pin set + Host github.com present → no synth, user's block carried (transforms applied)
#   AC4: idempotent — running twice on identical input produces identical output
#   AC5: missing host config → exit 0, output non-empty (header present, optional synth)
#   AC6: every IdentityFile in output uses /home/agent/.ssh/<basename>, basename matches host

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures/ssh-config"
FAILURES=0
TMPDIR_TEST=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  if [[ -n "${TMPDIR_TEST:-}" && -d "${TMPDIR_TEST:-}" ]]; then
    rm -rf "$TMPDIR_TEST"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Source rc to get function definitions
# ---------------------------------------------------------------------------
_source_rc_functions() {
  set +e
  # shellcheck source=../rc
  source "$RC" 2>/dev/null
  set -e
}
_source_rc_functions

# ---------------------------------------------------------------------------
# Setup: create a temp HOME with .ssh/ structure, substitute _SSH_HOME_ in fixtures.
# HOME is set to TMPDIR_TEST so that _translate_ssh_config resolves ${HOME}/.ssh
# to the temp SSH_DIR — this is the standard test isolation pattern.
# ---------------------------------------------------------------------------
TMPDIR_TEST=$(mktemp -d)
export HOME="${TMPDIR_TEST}"
SSH_DIR="${TMPDIR_TEST}/.ssh"
mkdir -p "$SSH_DIR"

# Copy included.conf into the temp .ssh/
cp "${FIXTURES}/included.conf" "${SSH_DIR}/included.conf"

# Replace _SSH_HOME_ placeholder with actual SSH_DIR in full fixture
sed "s|_SSH_HOME_|${SSH_DIR}|g" "${FIXTURES}/host-config-full.conf" > "${SSH_DIR}/config-full"

# Copy minimal and with-github fixtures (no placeholder)
cp "${FIXTURES}/host-config-minimal.conf" "${SSH_DIR}/config-minimal"
cp "${FIXTURES}/host-config-with-github.conf" "${SSH_DIR}/config-with-github"

# Cache dir for translated output
CACHE_DIR="${TMPDIR_TEST}/.cache/rip-cage/test-container"
mkdir -p "$CACHE_DIR"
OUTPUT="${CACHE_DIR}/ssh-config"

# ---------------------------------------------------------------------------
# Test 1 (AC1): Full fixture → IgnoreUnknown leads, paths rewritten, in-home Include
#              inlined (with paths rewritten), out-of-home Include stripped
# ---------------------------------------------------------------------------
echo "=== Test 1 (AC1): full fixture — IgnoreUnknown leads, paths rewritten, Include handling ==="

_translate_ssh_config "${SSH_DIR}/config-full" "$OUTPUT" ""

# AC1.1: IgnoreUnknown header is the first non-blank, non-comment line
first_directive=$(grep -v '^\s*#\|^\s*$' "$OUTPUT" | head -1)
if [[ "$first_directive" == IgnoreUnknown* ]]; then
  pass "AC1.1: IgnoreUnknown is the first directive"
else
  fail "AC1.1: first directive is not IgnoreUnknown, got: '$first_directive'"
fi

# AC1.2: IgnoreUnknown line covers UseKeychain and AddKeysToAgent
if grep -q "IgnoreUnknown.*UseKeychain.*AddKeysToAgent\|IgnoreUnknown.*AddKeysToAgent.*UseKeychain" "$OUTPUT"; then
  pass "AC1.2: IgnoreUnknown covers UseKeychain and AddKeysToAgent"
else
  fail "AC1.2: IgnoreUnknown does not cover both macOS directives"
fi

# AC1.3: No ~/.ssh/ paths remain outside of comments (all rewritten to /home/agent/.ssh/)
non_comment_tilde=$(grep -v '^\s*#' "$OUTPUT" | grep '~/.ssh/' | grep -v '# rip-cage' || true)
if [[ -z "$non_comment_tilde" ]]; then
  pass "AC1.3: no ~/.ssh/ paths remain outside comments"
else
  fail "AC1.3: ~/.ssh/ paths found outside comments: $non_comment_tilde"
fi

# AC1.4: IdentityFile paths rewritten to /home/agent/.ssh/<basename>
if grep -q "IdentityFile /home/agent/.ssh/" "$OUTPUT"; then
  pass "AC1.4: IdentityFile paths use /home/agent/.ssh/"
else
  fail "AC1.4: no /home/agent/.ssh/ IdentityFile paths found in output"
fi

# AC1.5: In-home Include's content is inlined (look for Host internal from included.conf)
if grep -q "Host internal" "$OUTPUT"; then
  pass "AC1.5: in-home Include content inlined (Host internal found)"
else
  fail "AC1.5: in-home Include content NOT inlined (Host internal missing)"
fi

# AC1.6: The Include line itself is gone (replaced by content)
if grep -q "^Include " "$OUTPUT"; then
  fail "AC1.6: Include directives still present in output (should be inlined or stripped)"
else
  pass "AC1.6: no Include directives remain"
fi

# AC1.7: Out-of-home Include is stripped with rip-cage comment
if grep -q "# rip-cage: stripped (Include outside" "$OUTPUT"; then
  pass "AC1.7: out-of-home Include replaced by rip-cage comment"
else
  fail "AC1.7: out-of-home Include not replaced by expected comment"
fi

# AC1.8: No host-absolute paths outside comments (i.e., /etc/orbstack left in non-comment)
non_comment_orbstack=$(grep -v '^\s*#' "$OUTPUT" | grep '/etc/orbstack' || true)
if [[ -z "$non_comment_orbstack" ]]; then
  pass "AC1.8: no out-of-home absolute paths remain outside comments"
else
  fail "AC1.8: absolute out-of-home paths remain: $non_comment_orbstack"
fi

# ---------------------------------------------------------------------------
# Test 2 (AC2): Host-only directives stripped, ADR-014 D2 overrides applied
# ---------------------------------------------------------------------------
echo "=== Test 2 (AC2): host-only directives stripped, ADR-014 D2 overrides ==="

# AC2.1: Match exec stripped
if grep -q "# rip-cage: stripped (host-only)" "$OUTPUT"; then
  pass "AC2.1: stripped (host-only) comment present"
else
  fail "AC2.1: no stripped (host-only) comment found"
fi

# Check each specific host-only directive is stripped (not as active directive)
for directive in "Match exec" "ProxyCommand" "ProxyJump" "ControlMaster" "ControlPath" "IdentityAgent"; do
  # Active directive lines (not in comments) should not contain these
  active_lines=$(grep -v '^\s*#' "$OUTPUT" | grep -i "^\s*${directive}" || true)
  if [[ -z "$active_lines" ]]; then
    pass "AC2.host-only: $directive is not present as active directive"
  else
    fail "AC2.host-only: $directive is still present as active directive: $active_lines"
  fi
done

# AC2.2: ADR-014 D2 — BatchMode no → BatchMode yes
batchmode_active=$(grep -v '^\s*#' "$OUTPUT" | grep -i "^\s*BatchMode" || true)
if echo "$batchmode_active" | grep -qi "BatchMode yes"; then
  pass "AC2.2: BatchMode overridden to yes"
else
  fail "AC2.2: BatchMode not overridden to yes (found: '$batchmode_active')"
fi

# Active BatchMode should not be 'no'
if echo "$batchmode_active" | grep -qi "BatchMode no"; then
  fail "AC2.2b: BatchMode no still present as active directive"
else
  pass "AC2.2b: BatchMode no is not present as active directive"
fi

# AC2.3: StrictHostKeyChecking accept-new → StrictHostKeyChecking yes
strict_active=$(grep -v '^\s*#' "$OUTPUT" | grep -i "^\s*StrictHostKeyChecking" || true)
if echo "$strict_active" | grep -qi "StrictHostKeyChecking yes"; then
  pass "AC2.3: StrictHostKeyChecking overridden to yes"
else
  fail "AC2.3: StrictHostKeyChecking not overridden to yes (found: '$strict_active')"
fi

if echo "$strict_active" | grep -qi "accept-new"; then
  fail "AC2.3b: StrictHostKeyChecking accept-new still present as active directive"
else
  pass "AC2.3b: StrictHostKeyChecking accept-new is not present as active directive"
fi

# AC2.4: UserKnownHostsFile overridden to /etc/ssh/ssh_known_hosts
ukh_active=$(grep -v '^\s*#' "$OUTPUT" | grep -i "^\s*UserKnownHostsFile" || true)
if echo "$ukh_active" | grep -q "UserKnownHostsFile /etc/ssh/ssh_known_hosts"; then
  pass "AC2.4: UserKnownHostsFile overridden to /etc/ssh/ssh_known_hosts"
else
  fail "AC2.4: UserKnownHostsFile not overridden correctly (found: '$ukh_active')"
fi

# AC2.5: GlobalKnownHostsFile overridden to /etc/ssh/ssh_known_hosts
gkh_active=$(grep -v '^\s*#' "$OUTPUT" | grep -i "^\s*GlobalKnownHostsFile" || true)
if echo "$gkh_active" | grep -q "GlobalKnownHostsFile /etc/ssh/ssh_known_hosts"; then
  pass "AC2.5: GlobalKnownHostsFile overridden to /etc/ssh/ssh_known_hosts"
else
  fail "AC2.5: GlobalKnownHostsFile not overridden correctly (found: '$gkh_active')"
fi

# AC2.6: Overrides are annotated with # rip-cage: overridden (ADR-014 D2)
if grep -q "# rip-cage: overridden (ADR-014 D2)" "$OUTPUT"; then
  pass "AC2.6: ADR-014 D2 override annotation present"
else
  fail "AC2.6: ADR-014 D2 override annotation missing"
fi

# ---------------------------------------------------------------------------
# Test 3 (AC3): github.com synthesis
# ---------------------------------------------------------------------------
echo "=== Test 3 (AC3): github.com synthesis ==="

# AC3.1: pin set + no Host github.com → synthesized block with IdentitiesOnly yes
_translate_ssh_config "${SSH_DIR}/config-minimal" "$OUTPUT" "id_ed25519_personal"

if grep -q "Host github.com" "$OUTPUT"; then
  pass "AC3.1: synthesized Host github.com block present"
else
  fail "AC3.1: no Host github.com block in output (should be synthesized)"
fi

if grep -q "IdentitiesOnly yes" "$OUTPUT"; then
  pass "AC3.1b: IdentitiesOnly yes present as active directive"
else
  fail "AC3.1b: IdentitiesOnly yes missing from synthesized block"
fi

# IdentitiesOnly must be an active directive (not a comment)
identities_active=$(grep -v '^\s*#' "$OUTPUT" | grep -i "IdentitiesOnly" || true)
if [[ -n "$identities_active" ]]; then
  pass "AC3.1c: IdentitiesOnly is present as active (non-commented) directive"
else
  fail "AC3.1c: IdentitiesOnly only appears in comments"
fi

# The synth block should reference the resolved key
if grep -q "IdentityFile /home/agent/.ssh/id_ed25519_personal" "$OUTPUT"; then
  pass "AC3.1d: synthesized block references correct key basename"
else
  fail "AC3.1d: synthesized block does not reference id_ed25519_personal"
fi

# AC3.2: pin set + Host github.com already present → no synthesized block, user's block carried
_translate_ssh_config "${SSH_DIR}/config-with-github" "$OUTPUT" "id_ed25519_personal"

# Count how many "Host github.com" lines appear — should be exactly 1
github_count=$(grep -c "^Host github.com" "$OUTPUT" || true)
if [[ "$github_count" -eq 1 ]]; then
  pass "AC3.2: exactly one Host github.com block (user's, not synthesized)"
else
  fail "AC3.2: expected exactly 1 Host github.com, found $github_count"
fi

# The user's block should have been carried with transforms applied (ControlMaster stripped)
control_master_active=$(grep -v '^\s*#' "$OUTPUT" | grep -i "^\s*ControlMaster" || true)
if [[ -z "$control_master_active" ]]; then
  pass "AC3.2b: ControlMaster stripped from user's Host github.com block"
else
  fail "AC3.2b: ControlMaster still present in user's github.com block"
fi

# ---------------------------------------------------------------------------
# Test 4 (AC4): Idempotency — running twice on identical input → identical output
# ---------------------------------------------------------------------------
echo "=== Test 4 (AC4): idempotency ==="

OUTPUT1="${CACHE_DIR}/ssh-config-run1"
OUTPUT2="${CACHE_DIR}/ssh-config-run2"

_translate_ssh_config "${SSH_DIR}/config-full" "$OUTPUT1" "id_ed25519_personal"
_translate_ssh_config "${SSH_DIR}/config-full" "$OUTPUT2" "id_ed25519_personal"

if diff "$OUTPUT1" "$OUTPUT2" >/dev/null 2>&1; then
  pass "AC4: two runs on same input produce identical output"
else
  fail "AC4: outputs differ between runs:"
  diff "$OUTPUT1" "$OUTPUT2" || true
fi

# ---------------------------------------------------------------------------
# Test 5 (AC5): Missing host config → exit 0, output non-empty with header
# ---------------------------------------------------------------------------
echo "=== Test 5 (AC5): missing host config → exit 0, non-empty output ==="

OUTPUT_MISSING="${CACHE_DIR}/ssh-config-missing"
exit_code=0
_translate_ssh_config "/no/such/ssh/config" "$OUTPUT_MISSING" "" || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
  pass "AC5.1: missing host config exits 0"
else
  fail "AC5.1: missing host config exited $exit_code (expected 0)"
fi

if [[ -f "$OUTPUT_MISSING" && -s "$OUTPUT_MISSING" ]]; then
  pass "AC5.2: output file exists and is non-empty"
else
  fail "AC5.2: output file missing or empty"
fi

first_missing=$(grep -v '^\s*#\|^\s*$' "$OUTPUT_MISSING" | head -1 || true)
if [[ "$first_missing" == IgnoreUnknown* ]]; then
  pass "AC5.3: output starts with IgnoreUnknown header"
else
  fail "AC5.3: output does not start with IgnoreUnknown, got: '$first_missing'"
fi

# AC5.4: with resolved key basename, missing config still synthesizes github.com block
OUTPUT_MISSING_KEY="${CACHE_DIR}/ssh-config-missing-key"
_translate_ssh_config "/no/such/ssh/config" "$OUTPUT_MISSING_KEY" "id_ed25519_work"
if grep -q "Host github.com" "$OUTPUT_MISSING_KEY"; then
  pass "AC5.4: missing config + pin → synthesized github.com block"
else
  fail "AC5.4: missing config + pin → no github.com block"
fi

# ---------------------------------------------------------------------------
# Test 6 (AC6): Every IdentityFile in output uses /home/agent/.ssh/<basename>
# ---------------------------------------------------------------------------
echo "=== Test 6 (AC6): all IdentityFile paths use /home/agent/.ssh/<basename> ==="

_translate_ssh_config "${SSH_DIR}/config-full" "$OUTPUT" "id_ed25519_personal"

# Extract all active IdentityFile lines
identityfile_lines=$(grep -v '^\s*#' "$OUTPUT" | grep -i "^\s*IdentityFile" || true)

if [[ -z "$identityfile_lines" ]]; then
  fail "AC6.1: no IdentityFile lines found in output"
else
  pass "AC6.1: IdentityFile lines present"
fi

# All IdentityFile values should start with /home/agent/.ssh/
bad_paths=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Extract the path portion: strip leading whitespace and "IdentityFile " keyword
  # Use bash parameter expansion (portable, no sed needed)
  path_val="${line#"${line%%[![:space:]]*}"}"  # strip leading whitespace
  path_val="${path_val#IdentityFile }"         # strip "IdentityFile " prefix (case-sensitive)
  if [[ "$path_val" != /home/agent/.ssh/* ]]; then
    bad_paths="${bad_paths}${line}
"
  fi
done <<< "$identityfile_lines"

if [[ -z "$bad_paths" ]]; then
  pass "AC6.2: all IdentityFile paths use /home/agent/.ssh/ prefix"
else
  fail "AC6.2: non-conforming IdentityFile paths found: $bad_paths"
fi

# Basenames in output should match basenames from host config
# The full fixture has: id_ed25519_work, id_ed25519_personal, id_ed25519_internal (from include)
expected_basenames=("id_ed25519_work" "id_ed25519_personal" "id_ed25519_internal")
all_ok=true
for bn in "${expected_basenames[@]}"; do
  if grep -q "IdentityFile /home/agent/.ssh/${bn}" "$OUTPUT"; then
    : # OK
  else
    fail "AC6.3: expected IdentityFile /home/agent/.ssh/${bn} not found"
    all_ok=false
  fi
done
if [[ "$all_ok" == "true" ]]; then
  pass "AC6.3: all expected key basenames present with correct path prefix"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== Results: $FAILURES failure(s) ==="
exit "$FAILURES"
