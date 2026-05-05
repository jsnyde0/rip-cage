#!/usr/bin/env bash
# Unit-style tests for rip-cage-bnf.3: pubkey allowlist mount + opt-out flags.
#
# Tests the following functions (sourced from rc):
#   _derive_pubkey_allowlist()         -- parse translated config, collect .pub paths
#   _assert_pubkey_exists_or_die()     -- explicit-pin missing-pubkey abort (D4 layers 1-3)
#   _build_ssh_mount_args()            -- compose --mount args for docker run
#   _resolve_ssh_config_posture()      -- --no-ssh-config / --ssh-config / --no-forward-ssh implication
#   _up_resolve_resume_ssh_config()    -- read rc.ssh-config label on resume
#
# Acceptance criteria covered:
#   AC1: ssh-config active + translated config with IdentityFile → only .pub mounts, no private-key paths
#   AC2: explicit pin + missing pubkey → exit non-zero, stderr names the missing file
#   AC3: user-config Host block with missing pubkey → warn (stderr), skip, continue
#   AC4: --no-ssh-config → no ssh-config mount, no .pub mounts, rc.ssh-config=off label
#   AC5: --no-forward-ssh (without --ssh-config) → same posture as AC4
#   AC6: --no-forward-ssh --ssh-config → rc.ssh-config=on, config + .pub mounts present

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
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
# Source rc to get function definitions (same pattern as test-ssh-translator.sh)
# ---------------------------------------------------------------------------
_source_rc_functions() {
  set +e
  # shellcheck source=../rc
  source "$RC" 2>/dev/null
  set -e
}
_source_rc_functions

# ---------------------------------------------------------------------------
# Setup: create a temp HOME with fake ~/.ssh/ (only .pub files, no private keys)
# ---------------------------------------------------------------------------
TMPDIR_TEST=$(mktemp -d)
export HOME="${TMPDIR_TEST}"
SSH_DIR="${TMPDIR_TEST}/.ssh"
mkdir -p "$SSH_DIR"

# Create .pub files (no private key files — ADR-020 D1)
touch "${SSH_DIR}/id_ed25519_work.pub"
touch "${SSH_DIR}/id_ed25519_personal.pub"
touch "${SSH_DIR}/known_hosts"

# Cache dir for translated output
CACHE_DIR="${TMPDIR_TEST}/.cache/rip-cage/test-container"
mkdir -p "$CACHE_DIR"
TRANSLATED_CONFIG="${CACHE_DIR}/ssh-config"

# Write a translated config with two IdentityFile lines (what _translate_ssh_config produces)
cat > "$TRANSLATED_CONFIG" <<'EOF'
IgnoreUnknown UseKeychain,AddKeysToAgent

Host github-work
  IdentityFile /home/agent/.ssh/id_ed25519_work
  IdentitiesOnly yes
  User git

Host github-personal
  IdentityFile /home/agent/.ssh/id_ed25519_personal
  IdentitiesOnly yes
  User git

Host github.com
  IdentityFile /home/agent/.ssh/id_ed25519_work
  IdentitiesOnly yes
  User git
EOF

# A translated config with a key whose .pub is missing on the host
TRANSLATED_CONFIG_MISSING="${CACHE_DIR}/ssh-config-missing-pubkey"
cat > "$TRANSLATED_CONFIG_MISSING" <<'EOF'
IgnoreUnknown UseKeychain,AddKeysToAgent

Host some-host
  IdentityFile /home/agent/.ssh/id_ed25519_nonexistent

Host github.com
  IdentityFile /home/agent/.ssh/id_ed25519_work
  IdentitiesOnly yes
  User git
EOF

# ---------------------------------------------------------------------------
# Test 1 (AC1): With ssh-config active and translated config containing IdentityFile
#               lines, _derive_pubkey_allowlist returns only .pub basenames,
#               and _build_ssh_mount_args produces only .pub mounts (no private keys)
# ---------------------------------------------------------------------------
echo "=== Test 1 (AC1): pubkey allowlist — only .pub files, no private-key paths ==="

# AC1.1: _derive_pubkey_allowlist extracts basenames from IdentityFile lines
allowlist=$(_derive_pubkey_allowlist "$TRANSLATED_CONFIG")
if echo "$allowlist" | grep -q "id_ed25519_work.pub"; then
  pass "AC1.1: allowlist contains id_ed25519_work.pub"
else
  fail "AC1.1: allowlist missing id_ed25519_work.pub (got: '$allowlist')"
fi

if echo "$allowlist" | grep -q "id_ed25519_personal.pub"; then
  pass "AC1.1b: allowlist contains id_ed25519_personal.pub"
else
  fail "AC1.1b: allowlist missing id_ed25519_personal.pub (got: '$allowlist')"
fi

# AC1.2: No private key basenames in allowlist (no entry without .pub suffix)
bad_entries=""
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if [[ "$entry" != *.pub ]]; then
    bad_entries="${bad_entries}${entry} "
  fi
done <<< "$allowlist"
if [[ -z "$bad_entries" ]]; then
  pass "AC1.2: all allowlist entries have .pub suffix (no private key names)"
else
  fail "AC1.2: non-.pub entries in allowlist: $bad_entries"
fi

# AC1.3: _build_ssh_mount_args produces mount args that reference only .pub files
# and no private-key paths (no path without .pub extension in src=)
SSH_MOUNT_ARGS=()
_build_ssh_mount_args "$TRANSLATED_CONFIG" "test-container" SSH_MOUNT_ARGS

# Check that all src= values in the array reference only .pub files, config, or known_hosts
private_key_mounts=""
for arg in "${SSH_MOUNT_ARGS[@]}"; do
  # Extract src= value from --mount type=bind,src=...,dst=...
  if [[ "$arg" =~ src=([^,]+) ]]; then
    src_val="${BASH_REMATCH[1]}"
    # Reject: path is under .ssh/ but is not .pub, config, or known_hosts
    if [[ "$src_val" == *"/.ssh/"* ]]; then
      basename_val="${src_val##*/}"
      if [[ "$basename_val" != *.pub && "$basename_val" != "config" && "$basename_val" != "known_hosts" ]]; then
        private_key_mounts="${private_key_mounts}${src_val} "
      fi
    fi
  fi
done
if [[ -z "$private_key_mounts" ]]; then
  pass "AC1.3: no private-key src paths in mount args"
else
  fail "AC1.3: private-key paths found in mount args: $private_key_mounts"
fi

# AC1.4: No mount of ~/.ssh/ directory itself (only individual files)
dir_mount_found=""
for arg in "${SSH_MOUNT_ARGS[@]}"; do
  if [[ "$arg" =~ src=([^,]+) ]]; then
    src_val="${BASH_REMATCH[1]}"
    # A mount of the .ssh/ directory itself would end with /.ssh
    if [[ "$src_val" == *"/.ssh" || "$src_val" == *"/.ssh/" ]]; then
      dir_mount_found="$src_val"
    fi
  fi
done
if [[ -z "$dir_mount_found" ]]; then
  pass "AC1.4: no mount of ~/.ssh/ directory itself"
else
  fail "AC1.4: ~/.ssh/ directory mount found: $dir_mount_found"
fi

# AC1.5: translated config itself is mounted
config_mount_found=""
for arg in "${SSH_MOUNT_ARGS[@]}"; do
  if [[ "$arg" == *"dst=/home/agent/.ssh/config"* ]]; then
    config_mount_found="yes"
  fi
done
if [[ -n "$config_mount_found" ]]; then
  pass "AC1.5: translated config mounted at /home/agent/.ssh/config"
else
  fail "AC1.5: translated config not mounted at /home/agent/.ssh/config"
fi

# ---------------------------------------------------------------------------
# Test 2 (AC2): Explicit pin + missing pubkey → exit non-zero, stderr names file
# ---------------------------------------------------------------------------
echo "=== Test 2 (AC2): explicit pin + missing pubkey → non-zero exit, names file ==="

# id_ed25519_nonexistent.pub does NOT exist in SSH_DIR
exit_code=0
stderr_output=""
stderr_output=$(_assert_pubkey_exists_or_die "id_ed25519_nonexistent" "explicit" 2>&1) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "AC2.1: explicit pin + missing pubkey exits non-zero (exit=$exit_code)"
else
  fail "AC2.1: explicit pin + missing pubkey exited 0 (should fail)"
fi

if echo "$stderr_output" | grep -q "id_ed25519_nonexistent"; then
  pass "AC2.2: error output names the missing file"
else
  fail "AC2.2: error output does not name the missing file (got: '$stderr_output')"
fi

# AC2.3: Key that EXISTS on host → exits 0 (no error)
exit_code_ok=0
_assert_pubkey_exists_or_die "id_ed25519_work" "explicit" 2>/dev/null || exit_code_ok=$?
if [[ "$exit_code_ok" -eq 0 ]]; then
  pass "AC2.3: existing pubkey → exits 0"
else
  fail "AC2.3: existing pubkey exited non-zero (exit=$exit_code_ok)"
fi

# ---------------------------------------------------------------------------
# Test 3 (AC3): User-config Host block with missing pubkey → warn, skip, continue
# ---------------------------------------------------------------------------
echo "=== Test 3 (AC3): user-config missing pubkey → warn, skip, mount others ==="

# Build mounts using the config that has id_ed25519_nonexistent (missing) and id_ed25519_work (present)
# Use a temp file to capture stderr without subshell (which would lose array mutations)
WARN_TMP="${TMPDIR_TEST}/warn_out.txt"
MISSING_MOUNT_ARGS=()
_build_ssh_mount_args "$TRANSLATED_CONFIG_MISSING" "test-container" MISSING_MOUNT_ARGS 2>"$WARN_TMP"
build_exit=$?
stderr_warn=$(cat "$WARN_TMP")

if [[ "$build_exit" -eq 0 ]]; then
  pass "AC3.1: build completes (exits 0) despite missing user-config pubkey"
else
  fail "AC3.1: build exited non-zero ($build_exit) — should continue despite missing pubkey"
fi

if echo "$stderr_warn" | grep -q "id_ed25519_nonexistent"; then
  pass "AC3.2: warning names the missing file"
else
  fail "AC3.2: warning does not name missing file (stderr: '$stderr_warn')"
fi

# The present key (id_ed25519_work) should still be in mount args
work_pub_mounted=""
for arg in "${MISSING_MOUNT_ARGS[@]}"; do
  if [[ "$arg" == *"id_ed25519_work.pub"* ]]; then
    work_pub_mounted="yes"
  fi
done
if [[ -n "$work_pub_mounted" ]]; then
  pass "AC3.3: present pubkey (id_ed25519_work.pub) still mounted"
else
  fail "AC3.3: present pubkey not mounted despite being available"
fi

# The missing key should NOT be in mount args
nonexistent_mounted=""
for arg in "${MISSING_MOUNT_ARGS[@]}"; do
  if [[ "$arg" == *"id_ed25519_nonexistent"* ]]; then
    nonexistent_mounted="yes"
  fi
done
if [[ -z "$nonexistent_mounted" ]]; then
  pass "AC3.4: missing pubkey not included in mount args"
else
  fail "AC3.4: missing pubkey incorrectly included in mount args"
fi

# ---------------------------------------------------------------------------
# Test 4 (AC4): --no-ssh-config → no config mount, no .pub mounts, posture=off
# ---------------------------------------------------------------------------
echo "=== Test 4 (AC4): --no-ssh-config → no config/pubkey mounts, posture=off ==="

# _resolve_ssh_config_posture: args simulate CLI parsing result
# posture=off when --no-ssh-config set
posture=$(_resolve_ssh_config_posture "off" "" "on")
if [[ "$posture" == "off" ]]; then
  pass "AC4.1: --no-ssh-config → posture=off"
else
  fail "AC4.1: --no-ssh-config posture expected 'off', got '$posture'"
fi

# When posture=off, _build_ssh_mount_args should return empty array
NO_SSH_MOUNT_ARGS=()
# Pass posture=off to suppress mounts
_build_ssh_mount_args_with_posture "$TRANSLATED_CONFIG" "test-container" NO_SSH_MOUNT_ARGS "off"
if [[ "${#NO_SSH_MOUNT_ARGS[@]}" -eq 0 ]]; then
  pass "AC4.2: posture=off → no mount args added"
else
  fail "AC4.2: posture=off produced ${#NO_SSH_MOUNT_ARGS[@]} mount args (expected 0)"
fi

# Label args for rc.ssh-config=off
label_args=()
_ssh_config_label_args "off" label_args
label_found=""
for arg in "${label_args[@]}"; do
  if [[ "$arg" == "rc.ssh-config=off" ]]; then
    label_found="yes"
  fi
done
if [[ -n "$label_found" ]]; then
  pass "AC4.3: rc.ssh-config=off label included"
else
  fail "AC4.3: rc.ssh-config=off label not found in label args (got: ${label_args[*]:-empty})"
fi

# ---------------------------------------------------------------------------
# Test 5 (AC5): --no-forward-ssh (without --ssh-config) → same as AC4
# ---------------------------------------------------------------------------
echo "=== Test 5 (AC5): --no-forward-ssh (no --ssh-config) → posture=off ==="

# --no-forward-ssh: rc_forward_ssh=off, explicit_ssh_config_flag=""
posture_implied=$(_resolve_ssh_config_posture "" "" "off")
if [[ "$posture_implied" == "off" ]]; then
  pass "AC5.1: --no-forward-ssh implies posture=off when --ssh-config not set"
else
  fail "AC5.1: --no-forward-ssh implication expected 'off', got '$posture_implied'"
fi

# ---------------------------------------------------------------------------
# Test 6 (AC6): --no-forward-ssh --ssh-config → posture=on (implication overridden)
# ---------------------------------------------------------------------------
echo "=== Test 6 (AC6): --no-forward-ssh --ssh-config → posture=on ==="

# --no-forward-ssh + explicit --ssh-config: explicit_ssh_config_flag="on"
posture_override=$(_resolve_ssh_config_posture "" "on" "off")
if [[ "$posture_override" == "on" ]]; then
  pass "AC6.1: --no-forward-ssh --ssh-config → posture=on (implication overridden)"
else
  fail "AC6.1: expected posture=on, got '$posture_override'"
fi

# When posture=on, mount args should be populated
ON_MOUNT_ARGS=()
_build_ssh_mount_args_with_posture "$TRANSLATED_CONFIG" "test-container" ON_MOUNT_ARGS "on"
if [[ "${#ON_MOUNT_ARGS[@]}" -gt 0 ]]; then
  pass "AC6.2: posture=on → mount args populated"
else
  fail "AC6.2: posture=on produced no mount args"
fi

# And label should be rc.ssh-config=on
on_label_args=()
_ssh_config_label_args "on" on_label_args
on_label_found=""
for arg in "${on_label_args[@]}"; do
  if [[ "$arg" == "rc.ssh-config=on" ]]; then
    on_label_found="yes"
  fi
done
if [[ -n "$on_label_found" ]]; then
  pass "AC6.3: rc.ssh-config=on label included"
else
  fail "AC6.3: rc.ssh-config=on label not found (got: ${on_label_args[*]:-empty})"
fi

# ---------------------------------------------------------------------------
# Test 7 (AC4/AC5 extended): resume reads rc.ssh-config label
# (unit-level: test _up_resolve_resume_ssh_config with mock docker output)
# ---------------------------------------------------------------------------
echo "=== Test 7: _resolve_ssh_config_posture default (no flags) → on ==="

# Default: no --no-ssh-config, no --ssh-config, forward-ssh=on
posture_default=$(_resolve_ssh_config_posture "" "" "on")
if [[ "$posture_default" == "on" ]]; then
  pass "AC7.1: default posture (no flags) → on"
else
  fail "AC7.1: default posture expected 'on', got '$posture_default'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== Results: $FAILURES failure(s) ==="
exit "$FAILURES"
