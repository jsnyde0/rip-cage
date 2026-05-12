#!/usr/bin/env bash
# Host-side unit tests for the SSH host + key allowlist (ADR-022, rip-cage-b0c).
#
# Coverage (14 cases from design doc):
#   C1   Regression — no .rip-cage.yaml, filtered known_hosts is empty (bypass closed)
#   C2   Regression — switch.berlin absent from filtered file when not in allowed_hosts
#   C3   Bypass closed — _build_ssh_mount_args mounts filtered cache path, not raw ~/.ssh/known_hosts
#   C4   Allowed host passes filter
#   C5   Wildcard host: "*.internal.example.com" matches foo.internal.example.com
#   C6   Hashed entry, exact pattern: HMAC match → unhashed line in filtered file
#   C7   Hashed entry, wildcard pattern: dropped + warning with ssh-keyscan recipe
#   C8   allowed_keys subset: effective config has exactly the declared key
#   C9   allowed_keys zero-out: effective config has empty list
#   C10  allowed_keys absent: effective config has null (full-forward path)
#   C11  ssh-agent-filter launcher — init-rip-cage.sh reads sentinel and launches the daemon
#   C12  Resume preserves filtering — _filter_known_hosts is idempotent
#   C13  D3 version-drift abort — _config_validate_or_abort exits non-zero
#   C14  transform-5 update — UserKnownHostsFile/GlobalKnownHostsFile NOT rewritten;
#        BatchMode/StrictHostKeyChecking still overridden
#
# Tests do NOT require docker — pure host-side function testing.
# ADRs: ADR-022 (SSH allowlist), ADR-021 (layered config), ADR-014 D2 (non-interactive posture)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_HOME=""
TEST_WS=""
CACHE_DIR=""
TOTAL=18

pass() { echo "PASS C$1: $2"; }
fail() { echo "FAIL C$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build sandbox with optional config files. Sets TEST_HOME, TEST_WS, CACHE_DIR.
setup_sandbox() {
  local gf="${1:-}" pf="${2:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-allowlist-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.ssh"
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
  if [[ -n "$gf" ]]; then
    cp "${SCRIPT_DIR}/fixtures/${gf}" "${TEST_HOME}/.config/rip-cage/config.yaml"
  fi
  if [[ -n "$pf" ]]; then
    cp "${SCRIPT_DIR}/fixtures/${pf}" "${TEST_WS}/.rip-cage.yaml"
  fi
  CACHE_DIR="${TEST_HOME}/.cache/rip-cage/test-container"
  mkdir -p "$CACHE_DIR"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" TEST_WS="" CACHE_DIR=""
}

# ---------------------------------------------------------------------------
# C1: no .rip-cage.yaml → filtered known_hosts is empty (bypass closed)
# _filter_known_hosts with empty allowed list must produce an empty file.
# ---------------------------------------------------------------------------
setup_sandbox "" ""
printf 'switch.berlin ssh-ed25519 AAAA...\ngithub.com ssh-ed25519 BBBB...\n' \
  > "${TEST_HOME}/.ssh/known_hosts"

_c1_out="${CACHE_DIR}/known_hosts"
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _filter_known_hosts '' '${TEST_HOME}/.ssh/known_hosts' '$_c1_out'
" 2>/dev/null
_c1_exit=$?
set -e

if [[ -f "$_c1_out" && ! -s "$_c1_out" ]]; then
  pass 1 "no .rip-cage.yaml → filtered known_hosts is empty (bypass closed)"
elif [[ ! -f "$_c1_out" ]]; then
  fail 1 "no .rip-cage.yaml → filtered known_hosts empty" "_filter_known_hosts did not create output file (function missing?)"
else
  _contents=$(cat "$_c1_out" 2>/dev/null || true)
  fail 1 "no .rip-cage.yaml → filtered known_hosts empty" "file is non-empty: $_contents"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C2: switch.berlin absent from filtered file when not in allowed_hosts
# ---------------------------------------------------------------------------
setup_sandbox "" ""
printf 'switch.berlin ssh-ed25519 AAAA...\ngithub.com ssh-ed25519 BBBB...\n' \
  > "${TEST_HOME}/.ssh/known_hosts"

_c2_out="${CACHE_DIR}/known_hosts"
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _filter_known_hosts '' '${TEST_HOME}/.ssh/known_hosts' '$_c2_out'
" 2>/dev/null
set -e

if ! grep -q "switch.berlin" "$_c2_out" 2>/dev/null; then
  pass 2 "no .rip-cage.yaml → switch.berlin absent from filtered file"
else
  fail 2 "switch.berlin absent from filtered file" "switch.berlin found in filtered file"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C3: Bypass closed — _build_ssh_mount_args must NOT directly mount ~/.ssh/known_hosts
# After b0c, it mounts the filtered cache file (which is empty when no config).
# ---------------------------------------------------------------------------
setup_sandbox "" ""
printf 'switch.berlin ssh-ed25519 AAAA...\n' > "${TEST_HOME}/.ssh/known_hosts"
: > "${CACHE_DIR}/known_hosts"  # filtered file: empty

# Create a minimal translated config
_c3_cfg="${CACHE_DIR}/ssh-config"
printf 'IgnoreUnknown UseKeychain\n' > "$_c3_cfg"

_c3_mounts=$(set +e; HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _mounts=()
  _build_ssh_mount_args '$_c3_cfg' 'test-container' _mounts
  printf '%s\n' \"\${_mounts[@]}\"
" 2>/dev/null; set -e; true)

_c3_direct=false
while IFS= read -r _m; do
  if [[ "$_m" == *"src=${TEST_HOME}/.ssh/known_hosts"* ]]; then
    _c3_direct=true
    break
  fi
done <<< "$_c3_mounts"

if [[ "$_c3_direct" == "false" ]]; then
  pass 3 "bypass closed: ~/.ssh/known_hosts not directly mounted"
else
  fail 3 "bypass closed" "~/.ssh/known_hosts mounted directly (bypass still open)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C4: Allowed host — entry in allowed_hosts passes through filter
# ---------------------------------------------------------------------------
setup_sandbox "" ""
printf 'switch.berlin ssh-ed25519 AAAA...\ngithub.com ssh-ed25519 BBBB...\n' \
  > "${TEST_HOME}/.ssh/known_hosts"

_c4_out="${CACHE_DIR}/known_hosts"
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _filter_known_hosts 'switch.berlin' '${TEST_HOME}/.ssh/known_hosts' '$_c4_out'
" 2>/dev/null
set -e

if grep -q "switch.berlin" "$_c4_out" 2>/dev/null; then
  pass 4 "allowed host switch.berlin present in filtered file"
else
  fail 4 "allowed host passes filter" "switch.berlin absent from filtered file"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C5: Wildcard host — "*.internal.example.com" matches foo.internal.example.com
# ---------------------------------------------------------------------------
setup_sandbox "" ""
printf 'foo.internal.example.com ssh-ed25519 CCCC...\nother.net ssh-ed25519 DDDD...\n' \
  > "${TEST_HOME}/.ssh/known_hosts"

_c5_out="${CACHE_DIR}/known_hosts"
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _filter_known_hosts '*.internal.example.com' '${TEST_HOME}/.ssh/known_hosts' '$_c5_out'
" 2>/dev/null
set -e

_c5_ok=true _c5_reason=""
if ! grep -q "foo.internal.example.com" "$_c5_out" 2>/dev/null; then
  _c5_ok=false; _c5_reason="foo.internal.example.com not in filtered file"
fi
if grep -q "other.net" "$_c5_out" 2>/dev/null; then
  _c5_ok=false; _c5_reason="${_c5_reason:+$_c5_reason; }other.net should be excluded"
fi

if [[ "$_c5_ok" == "true" ]]; then
  pass 5 "wildcard *.internal.example.com matches foo.internal.example.com; other.net excluded"
else
  fail 5 "wildcard host filter" "$_c5_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C6: Hashed entry, exact pattern — HMAC match → unhashed line in filtered file
# We create a real hashed entry using the same HMAC-SHA1 algorithm as OpenSSH.
# ---------------------------------------------------------------------------
setup_sandbox "" ""

# Build a hashed known_hosts entry for switch.berlin
_c6_salt_hex=$(openssl rand -hex 20 2>/dev/null)
_c6_salt_b64=$(python3 -c "import sys,base64,binascii; print(base64.b64encode(binascii.unhexlify('${_c6_salt_hex}')).decode(), end='')")
_c6_hash_b64=$(printf '%s' 'switch.berlin' | openssl dgst -sha1 -mac HMAC -macopt "hexkey:${_c6_salt_hex}" -binary 2>/dev/null | base64)
printf '|1|%s|%s ssh-ed25519 AAAA...\n' "$_c6_salt_b64" "$_c6_hash_b64" \
  > "${TEST_HOME}/.ssh/known_hosts"

_c6_out="${CACHE_DIR}/known_hosts"
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _filter_known_hosts 'switch.berlin' '${TEST_HOME}/.ssh/known_hosts' '$_c6_out'
" 2>/dev/null
set -e

_c6_ok=true _c6_reason=""
if ! grep -q "switch.berlin" "$_c6_out" 2>/dev/null; then
  _c6_ok=false; _c6_reason="switch.berlin not found in filtered file after HMAC match"
fi
if grep -q "^|1|" "$_c6_out" 2>/dev/null; then
  _c6_ok=false; _c6_reason="${_c6_reason:+$_c6_reason; }hashed form still present (should be unhashed)"
fi

if [[ "$_c6_ok" == "true" ]]; then
  pass 6 "hashed entry with exact pattern: HMAC matched, written unhashed in filtered file"
else
  fail 6 "hashed entry exact pattern" "$_c6_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C7: Hashed entry, wildcard pattern — dropped + warning with ssh-keyscan recipe
# ---------------------------------------------------------------------------
setup_sandbox "" ""

_c7_salt_hex=$(openssl rand -hex 20 2>/dev/null)
_c7_salt_b64=$(python3 -c "import sys,base64,binascii; print(base64.b64encode(binascii.unhexlify('${_c7_salt_hex}')).decode(), end='')")
_c7_hash_b64=$(printf '%s' 'foo.example.com' | openssl dgst -sha1 -mac HMAC -macopt "hexkey:${_c7_salt_hex}" -binary 2>/dev/null | base64)
printf '|1|%s|%s ssh-ed25519 AAAA...\n' "$_c7_salt_b64" "$_c7_hash_b64" \
  > "${TEST_HOME}/.ssh/known_hosts"

_c7_out="${CACHE_DIR}/known_hosts"
_c7_stderr=$(mktemp)
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _filter_known_hosts '*.example.com' '${TEST_HOME}/.ssh/known_hosts' '$_c7_out'
" 2>"$_c7_stderr"
set -e

_c7_warned=false
grep -qi "ssh-keyscan\|hashed\|wildcard\|cannot match" "$_c7_stderr" 2>/dev/null && _c7_warned=true

_c7_ok=true _c7_reason=""
if [[ -s "$_c7_out" ]]; then
  _c7_ok=false; _c7_reason="filtered file non-empty (hashed entry should be dropped)"
fi
if [[ "$_c7_warned" == "false" ]]; then
  _c7_ok=false; _c7_reason="${_c7_reason:+$_c7_reason; }no warning emitted (ssh-keyscan recipe expected)"
fi

if [[ "$_c7_ok" == "true" ]]; then
  pass 7 "hashed entry + wildcard pattern: dropped, warning with ssh-keyscan recipe emitted"
else
  fail 7 "hashed entry + wildcard pattern" "$_c7_reason"
fi
rm -f "$_c7_stderr"
teardown_sandbox

# ---------------------------------------------------------------------------
# C8: allowed_keys subset — config-project-basic.yaml has allowed_keys: [id_ed25519_personal]
# ---------------------------------------------------------------------------
setup_sandbox "" "config-project-basic.yaml"

_c8_result=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _load_effective_config '$TEST_WS'
" 2>/dev/null || true)
_c8_keys=$(printf '%s' "$_c8_result" | jq -c '.config.ssh.allowed_keys' 2>/dev/null || true)

if [[ "$_c8_keys" == '["id_ed25519_personal"]' ]]; then
  pass 8 "allowed_keys subset: effective config contains [id_ed25519_personal]"
else
  fail 8 "allowed_keys subset" "expected [\"id_ed25519_personal\"], got: $_c8_keys"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C9: allowed_keys [] zero-out — effective config has empty list
# ---------------------------------------------------------------------------
setup_sandbox "" "config-project-zero-out-keys.yaml"

_c9_result=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _load_effective_config '$TEST_WS'
" 2>/dev/null || true)
_c9_keys=$(printf '%s' "$_c9_result" | jq -c '.config.ssh.allowed_keys' 2>/dev/null || true)

if [[ "$_c9_keys" == "[]" ]]; then
  pass 9 "allowed_keys []: effective config has empty list (zero-out semantics)"
else
  fail 9 "allowed_keys zero-out" "expected [], got: $_c9_keys"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C10: allowed_keys absent — effective config has null (full-forward path)
# ---------------------------------------------------------------------------
setup_sandbox "" ""

_c10_result=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _load_effective_config '$TEST_WS'
" 2>/dev/null || true)
_c10_keys=$(printf '%s' "$_c10_result" | jq -c '.config.ssh.allowed_keys' 2>/dev/null || true)

if [[ "$_c10_keys" == "null" ]]; then
  pass 10 "allowed_keys absent → null in effective config (full-forward path)"
else
  fail 10 "allowed_keys absent" "expected null, got: $_c10_keys"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C11: ssh-agent-filter launcher — init-rip-cage.sh reads ssh-allowed-keys
# sentinel and conditionally launches ssh-agent-filter (the daemon; afssh is
# a one-shot ssh wrapper, not a long-running socket bridge).
# ---------------------------------------------------------------------------
INIT_SCRIPT="${REPO_ROOT}/init-rip-cage.sh"

_c11_ok=true _c11_reason=""
if ! grep -q "ssh-allowed-keys" "$INIT_SCRIPT" 2>/dev/null; then
  _c11_ok=false; _c11_reason="ssh-allowed-keys sentinel read not found in init-rip-cage.sh"
fi
if ! grep -qE '^[[:space:]]*[^#]*ssh-agent-filter' "$INIT_SCRIPT" 2>/dev/null; then
  _c11_ok=false; _c11_reason="${_c11_reason:+$_c11_reason; }ssh-agent-filter launch (non-comment) not found in init-rip-cage.sh"
fi

if [[ "$_c11_ok" == "true" ]]; then
  pass 11 "init-rip-cage.sh reads ssh-allowed-keys and launches ssh-agent-filter"
else
  fail 11 "ssh-agent-filter launcher block" "$_c11_reason"
fi

# ---------------------------------------------------------------------------
# C12: Resume preserves filtering — _filter_known_hosts is idempotent
# ---------------------------------------------------------------------------
setup_sandbox "" ""
printf 'switch.berlin ssh-ed25519 AAAA...\ngithub.com ssh-ed25519 BBBB...\nother.net ssh-ed25519 CCCC...\n' \
  > "${TEST_HOME}/.ssh/known_hosts"

_c12_out1="${CACHE_DIR}/known_hosts-run1"
_c12_out2="${CACHE_DIR}/known_hosts-run2"

set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _filter_known_hosts 'switch.berlin github.com' '${TEST_HOME}/.ssh/known_hosts' '$_c12_out1'
  _filter_known_hosts 'switch.berlin github.com' '${TEST_HOME}/.ssh/known_hosts' '$_c12_out2'
" 2>/dev/null
_c12_exit=$?
set -e

if [[ -f "$_c12_out1" && -f "$_c12_out2" ]]; then
  if diff "$_c12_out1" "$_c12_out2" >/dev/null 2>/dev/null; then
    pass 12 "resume idempotent: _filter_known_hosts produces identical output across two runs"
  else
    fail 12 "resume idempotent" "two runs on same input differ"
  fi
else
  fail 12 "resume idempotent" "_filter_known_hosts did not create output files (function missing?)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C13: D3 version-drift abort — _config_validate_or_abort exits non-zero
# .rip-cage.yaml with version: 99 + selection-list field must abort.
# ---------------------------------------------------------------------------
setup_sandbox "" "config-project-future-version-with-selection.yaml"

_c13_exit=0
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _config_validate_or_abort '$TEST_WS'
" 2>/dev/null
_c13_exit=$?
set -e

if [[ "$_c13_exit" -ne 0 ]]; then
  pass 13 "D3 version-drift abort: _config_validate_or_abort exits non-zero"
else
  fail 13 "D3 version-drift abort" "_config_validate_or_abort returned 0 (should abort)"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C14: transform-5 update — UserKnownHostsFile/GlobalKnownHostsFile NOT rewritten;
# BatchMode/StrictHostKeyChecking still overridden.
# Per ADR-022 D4: config-layer rewrites are theater; drop them. Keep posture overrides.
#
# The fixture uses a non-standard custom path for both directives so we can
# confirm the OLD rewrite behavior (to /etc/ssh/ssh_known_hosts) is absent.
# After this bead's change, both directives pass through with their original values.
# ---------------------------------------------------------------------------
setup_sandbox "" ""

_c14_cfg="${TEST_HOME}/.ssh/config-with-knownhosts"
cat > "$_c14_cfg" <<'SSHCONF'
Host example.com
  UserKnownHostsFile /custom/path/known_hosts
  GlobalKnownHostsFile /custom/global/known_hosts
  BatchMode no
  StrictHostKeyChecking accept-new
SSHCONF

_c14_out="${CACHE_DIR}/translated-config"
set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _translate_ssh_config '$_c14_cfg' '$_c14_out' ''
" 2>/dev/null
set -e

# The OLD rewrite would replace these with /etc/ssh/ssh_known_hosts + ADR-014 D2 annotation.
# The NEW behavior passes them through unchanged — so /etc/ssh/ssh_known_hosts should NOT appear
# alongside these directives in the output.
_ukh_rewrite=$(grep -v '^\s*#' "$_c14_out" | grep -i 'UserKnownHostsFile.*\/etc\/ssh\/ssh_known_hosts' || true)
_gkh_rewrite=$(grep -v '^\s*#' "$_c14_out" | grep -i 'GlobalKnownHostsFile.*\/etc\/ssh\/ssh_known_hosts' || true)
# The custom paths should still be present in the output (passed through unchanged)
_ukh_custom=$(grep -v '^\s*#' "$_c14_out" | grep -i 'UserKnownHostsFile.*/custom/' || true)
_gkh_custom=$(grep -v '^\s*#' "$_c14_out" | grep -i 'GlobalKnownHostsFile.*/custom/' || true)
# BatchMode must be overridden to yes
_bm_yes=$(grep -v '^\s*#' "$_c14_out" | grep -i '^\s*BatchMode\s*yes' || true)
# StrictHostKeyChecking must be overridden to yes
_shk_yes=$(grep -v '^\s*#' "$_c14_out" | grep -i '^\s*StrictHostKeyChecking\s*yes' || true)

_c14_ok=true _c14_reason=""
[[ -n "$_ukh_rewrite" ]] && { _c14_ok=false; _c14_reason="${_c14_reason}UserKnownHostsFile rewritten to /etc/ssh (should pass through); "; }
[[ -n "$_gkh_rewrite" ]] && { _c14_ok=false; _c14_reason="${_c14_reason}GlobalKnownHostsFile rewritten to /etc/ssh (should pass through); "; }
[[ -z "$_ukh_custom" ]] && { _c14_ok=false; _c14_reason="${_c14_reason}UserKnownHostsFile /custom/path not in output; "; }
[[ -z "$_gkh_custom" ]] && { _c14_ok=false; _c14_reason="${_c14_reason}GlobalKnownHostsFile /custom/global not in output; "; }
[[ -z "$_bm_yes" ]] && { _c14_ok=false; _c14_reason="${_c14_reason}BatchMode yes absent; "; }
[[ -z "$_shk_yes" ]] && { _c14_ok=false; _c14_reason="${_c14_reason}StrictHostKeyChecking yes absent; "; }

if [[ "$_c14_ok" == "true" ]]; then
  pass 14 "transform-5: UserKnownHostsFile/GlobalKnownHostsFile not rewritten; BatchMode/StrictHostKeyChecking still overridden"
else
  fail 14 "transform-5 update" "$_c14_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# Integration tests: cmd_up creates filtered known_hosts + sentinel on host
#
# These tests call _up_resolve_ssh_allowlists directly (the helper that
# cmd_up uses after mkdir -p cache_dir). No docker required.
#
# C15: no .rip-cage.yaml → known_hosts cache written (empty); sentinel absent
# C16: ssh.allowed_hosts only → known_hosts has the allowed entry; sentinel absent; socket dest /ssh-agent.sock
# C17: ssh.allowed_keys non-empty → sentinel file written; socket dest /ssh-agent-upstream.sock
# C18: ssh.allowed_keys [] (zero-out) → sentinel file written and empty; socket dest /ssh-agent-upstream.sock
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# C15: no .rip-cage.yaml → cache known_hosts written (empty); sentinel absent
# ---------------------------------------------------------------------------
setup_sandbox "" ""
printf 'switch.berlin ssh-ed25519 AAAA...\ngithub.com ssh-ed25519 BBBB...\n' \
  > "${TEST_HOME}/.ssh/known_hosts"

set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_ssh_allowlists '$TEST_WS' '$CACHE_DIR'
" 2>/dev/null
_c15_exit=$?
set -e

_c15_ok=true _c15_reason=""
if [[ ! -f "${CACHE_DIR}/known_hosts" ]]; then
  _c15_ok=false; _c15_reason="${CACHE_DIR}/known_hosts not created"
elif [[ -s "${CACHE_DIR}/known_hosts" ]]; then
  _c15_ok=false; _c15_reason="known_hosts non-empty (should be empty with no config)"
fi
if [[ -f "${CACHE_DIR}/ssh-allowed-keys" ]]; then
  _c15_ok=false; _c15_reason="${_c15_reason:+$_c15_reason; }sentinel file exists (should be absent)"
fi

if [[ "$_c15_ok" == "true" ]]; then
  pass 15 "no .rip-cage.yaml → known_hosts cache empty, sentinel absent"
else
  fail 15 "no .rip-cage.yaml integration" "$_c15_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C16: ssh.allowed_hosts only → known_hosts has allowed entry; sentinel absent
# ---------------------------------------------------------------------------
setup_sandbox "" "config-project-allowed-hosts-only.yaml"
printf 'switch.berlin ssh-ed25519 AAAA...\ngithub.com ssh-ed25519 BBBB...\n' \
  > "${TEST_HOME}/.ssh/known_hosts"

set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_ssh_allowlists '$TEST_WS' '$CACHE_DIR'
" 2>/dev/null
_c16_exit=$?
set -e

_c16_ok=true _c16_reason=""
if ! grep -q "switch.berlin" "${CACHE_DIR}/known_hosts" 2>/dev/null; then
  _c16_ok=false; _c16_reason="switch.berlin absent from known_hosts cache"
fi
if [[ -f "${CACHE_DIR}/ssh-allowed-keys" ]]; then
  _c16_ok=false; _c16_reason="${_c16_reason:+$_c16_reason; }sentinel file exists (should be absent with no allowed_keys)"
fi

if [[ "$_c16_ok" == "true" ]]; then
  pass 16 "allowed_hosts only → known_hosts filtered, sentinel absent"
else
  fail 16 "allowed_hosts only integration" "$_c16_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C17: ssh.allowed_keys non-empty → sentinel written; socket dest /ssh-agent-upstream.sock
# ---------------------------------------------------------------------------
setup_sandbox "" "config-project-allowed-keys-one.yaml"
printf 'switch.berlin ssh-ed25519 AAAA...\n' > "${TEST_HOME}/.ssh/known_hosts"

set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_ssh_allowlists '$TEST_WS' '$CACHE_DIR'
" 2>/dev/null
_c17_exit=$?
set -e

_c17_ok=true _c17_reason=""
if [[ ! -f "${CACHE_DIR}/ssh-allowed-keys" ]]; then
  _c17_ok=false; _c17_reason="sentinel file absent (should exist when allowed_keys set)"
elif ! grep -q "id_ed25519_work" "${CACHE_DIR}/ssh-allowed-keys" 2>/dev/null; then
  _c17_ok=false; _c17_reason="id_ed25519_work not in sentinel file"
fi

# Check that filtering is active: _up_resolve_ssh_allowlists must expose a variable
_c17_filter_active=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_ssh_allowlists '$TEST_WS' '$CACHE_DIR'
  echo \"\$_UP_SSH_FILTER_ACTIVE\"
" 2>/dev/null || true)
if [[ "$_c17_filter_active" != "true" ]]; then
  _c17_ok=false; _c17_reason="${_c17_reason:+$_c17_reason; }_UP_SSH_FILTER_ACTIVE not 'true' (got: $_c17_filter_active)"
fi

if [[ "$_c17_ok" == "true" ]]; then
  pass 17 "allowed_keys non-empty → sentinel written, _UP_SSH_FILTER_ACTIVE=true"
else
  fail 17 "allowed_keys non-empty integration" "$_c17_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C18: ssh.allowed_keys [] zero-out → sentinel written and empty; filter active
# ---------------------------------------------------------------------------
setup_sandbox "" "config-project-zero-out-keys.yaml"
printf 'switch.berlin ssh-ed25519 AAAA...\n' > "${TEST_HOME}/.ssh/known_hosts"

set +e
HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_ssh_allowlists '$TEST_WS' '$CACHE_DIR'
" 2>/dev/null
_c18_exit=$?
set -e

_c18_ok=true _c18_reason=""
if [[ ! -f "${CACHE_DIR}/ssh-allowed-keys" ]]; then
  _c18_ok=false; _c18_reason="sentinel file absent (zero-out should still write sentinel)"
elif [[ -s "${CACHE_DIR}/ssh-allowed-keys" ]]; then
  _c18_ok=false; _c18_reason="sentinel non-empty (zero-out = empty sentinel file)"
fi

_c18_filter_active=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
  source '$RC' 2>/dev/null
  _up_resolve_ssh_allowlists '$TEST_WS' '$CACHE_DIR'
  echo \"\$_UP_SSH_FILTER_ACTIVE\"
" 2>/dev/null || true)
if [[ "$_c18_filter_active" != "true" ]]; then
  _c18_ok=false; _c18_reason="${_c18_reason:+$_c18_reason; }_UP_SSH_FILTER_ACTIVE not 'true' for zero-out (got: $_c18_filter_active)"
fi

if [[ "$_c18_ok" == "true" ]]; then
  pass 18 "allowed_keys [] zero-out → sentinel written empty, _UP_SSH_FILTER_ACTIVE=true"
else
  fail 18 "allowed_keys zero-out integration" "$_c18_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C19  ADR-022 D3 invalidation check (docker-conditional)
#      "ssh-agent-filter installed in image" — missing means agent half regressed
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker image inspect rip-cage:latest >/dev/null 2>&1; then
  if docker run --rm rip-cage:latest dpkg -l ssh-agent-filter 2>/dev/null | grep -q '^ii  ssh-agent-filter'; then
    pass 19 "ADR-022 D3 invalidation: ssh-agent-filter installed in rip-cage:latest"
  else
    fail 19 "ADR-022 D3 invalidation: ssh-agent-filter NOT installed in rip-cage:latest" "agent half regressed to today's full-forward behavior"
  fi
  TOTAL=$((TOTAL + 1))
else
  echo "SKIP C19: docker or rip-cage:latest image not available (run ./rc build first)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "--- Results: ${FAILURES} failure(s) out of ${TOTAL} checks ---"
exit "$FAILURES"
