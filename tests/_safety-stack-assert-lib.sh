#!/usr/bin/env bash
# _safety-stack-assert-lib.sh — Shared assert-present helpers (rip-cage-m8zc)
#
# Sourceable by BOTH test-safety-stack.sh and test-mount-seam-integration.sh.
# Contains ONLY function definitions + RC_ASSERTED_FILE default.
# Must NOT execute any checks at source-time (definitions only).
#
# In-cage: sourced from /usr/local/lib/rip-cage/ (both files in same dir).
# Host/CI: sourced from tests/ (both files in same dir).
# COPY'd to /usr/local/lib/rip-cage/_safety-stack-assert-lib.sh by Dockerfile.

# ---------------------------------------------------------------------------
# assert-present generic runner (rip-cage-m8zc)
# ---------------------------------------------------------------------------
# RC_ASSERTED_FILE: path to the baked safety-stack-asserted declaration.
# Default: /etc/rip-cage/safety-stack-asserted (root:root 0644).
# Override at test time to point at a fixture file (positive-control path).
RC_ASSERTED_FILE="${RC_ASSERTED_FILE:-/etc/rip-cage/safety-stack-asserted}"

# _run_asserted_checks
# Reads the asserted-file; for each line (<entry-id> <base64-check>), decodes
# and runs the check. Fail-closed: empty file, unparseable lines, or a failing
# check all result in FAIL. File-absent is minimal cage (skip, return 0).
#
# Requires: check() defined in the caller's scope (called for each entry).
# Returns: 0 if all checks pass (or file absent); non-zero if any FAIL.
#
# Line format: "<entry-id> <base64(check-cmd)>"
#   - entry-id: human-legible id (space-free per validator); used only for output.
#   - base64(check-cmd): standard base64 of the shell command to run.
# NOTE: The lib NEVER branches on entry-id — it runs the decoded check verbatim.
_run_asserted_checks() {
  local asserted_file="${RC_ASSERTED_FILE}"

  # File absent → minimal cage; nothing asserted; skip (valid state).
  [[ ! -f "$asserted_file" ]] && return 0

  # File present but empty → fail-closed (not a clean "no assertions" state).
  local content
  content=$(cat "$asserted_file" 2>/dev/null || true)
  if [[ -z "$content" ]]; then
    check "safety-stack-asserted: file present but EMPTY (fail-closed — expected at least one required tool)" "fail" \
      "${asserted_file} is empty; a present asserted-file with no entries is not a valid minimal-cage state"
    return 1
  fi

  local any_fail=0
  local line entry_id b64_check check_cmd check_exit
  while IFS= read -r line; do
    # Skip blank lines (defensive).
    [[ -z "$line" ]] && continue

    # Expect exactly two space-separated fields: <id> <b64>.
    entry_id="${line%% *}"
    b64_check="${line#* }"

    # Reject unparseable lines (only one field or empty fields).
    if [[ -z "$entry_id" || -z "$b64_check" || "$entry_id" == "$b64_check" ]]; then
      check "safety-stack-asserted: unparseable line in ${asserted_file} (fail-closed)" "fail" \
        "line='${line}' — expected '<entry-id> <base64(check)>' format"
      any_fail=1
      continue
    fi

    # Decode the check command (fail-closed on base64 decode failure).
    check_cmd=$(printf '%s' "$b64_check" | base64 -d 2>/dev/null) || {
      check "safety-stack-asserted: base64 decode FAILED for entry '${entry_id}' (fail-closed)" "fail" \
        "b64='${b64_check}' — corrupt asserted-file entry"
      any_fail=1
      continue
    }

    # Run the decoded check command verbatim. Non-zero exit → tool absent/inactive → FAIL.
    check_exit=0
    bash -c "$check_cmd" 2>/dev/null || check_exit=$?
    if [[ "$check_exit" -eq 0 ]]; then
      check "required tool '${entry_id}': asserted-present check passed" "pass" \
        "check='${check_cmd}'"
    else
      check "required tool '${entry_id}': asserted-present check FAILED (declared required but check returned non-zero)" "fail" \
        "check='${check_cmd}' exit=${check_exit} — default cage lost a declared required tool (rip-cage-m8zc)"
      any_fail=1
    fi
  done < "$asserted_file"

  [[ "$any_fail" -eq 0 ]] && return 0 || return 1
}
