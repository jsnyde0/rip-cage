#!/usr/bin/env bash
# _safety-stack-assert-lib.sh — Shared assert-present helpers (rip-cage-wlwc.6)
#
# Sourceable by BOTH test-safety-stack.sh and test-mount-seam-integration.sh.
# Contains ONLY function definitions + RC_ASSERTED_FILE default.
# Must NOT execute any checks at source-time (definitions only).
#
# In-cage: sourced from /usr/local/lib/rip-cage/ (both files in same dir).
# Host/CI: sourced from tests/ (both files in same dir).
# COPY'd to /usr/local/lib/rip-cage/_safety-stack-assert-lib.sh by Dockerfile.

# ---------------------------------------------------------------------------
# assert-present flip helper (rip-cage-wlwc.6)
# ---------------------------------------------------------------------------
# RC_ASSERTED_FILE: path to the baked safety-stack-asserted declaration.
# Default: /etc/rip-cage/safety-stack-asserted (root:root 0644).
# Override at test time to point at a fixture file (positive-control path).
RC_ASSERTED_FILE="${RC_ASSERTED_FILE:-/etc/rip-cage/safety-stack-asserted}"

# _guard_is_asserted <guard-id>
# Returns 0 if <guard-id> is listed in the asserted-file; 1 otherwise.
# Fail-closed: file PRESENT-but-empty or unparseable → returns 0 (treat as
# asserted-but-unmatchable; the calling check will then FAIL on absence).
_guard_is_asserted() {
  local guard_id="$1"
  local asserted_file="${RC_ASSERTED_FILE}"

  # File absent → minimal cage; nothing asserted; guard is NOT asserted.
  [[ ! -f "$asserted_file" ]] && return 1

  # File present but empty → fail-closed (not a clean "no assertions" state).
  # Return 0 so the calling check treats this as "asserted-but-absent" → FAIL.
  local content
  content=$(cat "$asserted_file" 2>/dev/null || true)
  if [[ -z "$content" ]]; then
    return 0  # fail-closed: empty file → guard treated as asserted → caller FAILs on absence
  fi

  # Check if guard_id appears as an exact line in the file.
  grep -qxF "$guard_id" "$asserted_file" 2>/dev/null
}

# _assert_ssh_bypass_present
# Called when ssh-bypass is in the asserted-file but the hook binary is absent.
# Emits a FAIL (not INFO-skip) because the default cage declared ssh-bypass but it's missing.
# This is a SINGLE function exercised by BOTH the real in-cage path AND the Tier-1 fixture
# positive control (via RC_ASSERTED_FILE override) — same code path, per CORRECTION B.
# NOTE: calls check() which is resolved dynamically at call-time from the consumer's scope.
_assert_ssh_bypass_present() {
  check "ssh-bypass asserted-present but hook absent (floor_assert + missing hook = regression)" "fail" \
    "floor_assert declared 'ssh-bypass' in ${RC_ASSERTED_FILE} but /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh is absent — default cage lost its composed guard (rip-cage-wlwc.6)"
}
