#!/usr/bin/env bash
# cli/auth.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# _extract_credentials — extract OAuth credentials from macOS Keychain to
# ~/.claude/.credentials.json. No-op on Linux (no Keychain).
#
# Test seam: set RC_SKIP_KEYCHAIN_EXTRACTION=1 to bypass the macOS keychain
# extraction entirely (used by e2e tests that need a deterministic no-auth cage).
# Affects BOTH `rc up` and `rc auth refresh` (both call this fn). Default-off;
# when set it warns loudly (below) so an accidental shell `export` surfaces
# instead of silently starting a no-credentials cage. DO NOT export in a real shell.
#
# Returns: 0 on success or on Linux, 1 on macOS extraction failure.

# _extract_credentials_has_usable_existing — rip-cage-towm: does a usable
# credential file ALREADY exist at ~/.claude/.credentials.json? "Usable" =
# exists, non-empty, and (best-effort) not expired per the same jq expiry
# idiom used elsewhere (rc ~1345-1354, D3 credential health check). No jq, no
# expiry field, or an unparsable expiry date all fall back to "usable"
# (best-effort — see the design's own invalidation clause: a stale-but-present
# file could theoretically suppress a warning that should fire; revisit if
# that turns out to bite in practice). Used to decide whether a keychain
# extraction failure is a genuine problem or a benign no-op (the existing
# file gets mounted regardless of extraction outcome).
_extract_credentials_has_usable_existing() {
  local creds_file="${HOME}/.claude/.credentials.json"
  [[ -s "$creds_file" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 0
  local expiry
  expiry=$(jq -r '.expiry // .expiresAt // empty' "$creds_file" 2>/dev/null || true)
  [[ -z "$expiry" ]] && return 0
  local expiry_epoch now_epoch
  expiry_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${expiry%%[.+Z]*}" "+%s" 2>/dev/null || date -d "$expiry" "+%s" 2>/dev/null || true)
  [[ -z "$expiry_epoch" ]] && return 0
  now_epoch=$(date "+%s")
  [[ "$expiry_epoch" -gt "$now_epoch" ]]
}


_extract_credentials() {
  # Test seam: skip keychain extraction when explicitly requested. Warn loudly so
  # an accidental export surfaces instead of silently producing a no-auth cage.
  if [[ "${RC_SKIP_KEYCHAIN_EXTRACTION:-0}" == "1" ]]; then
    echo "Warning: RC_SKIP_KEYCHAIN_EXTRACTION=1 — skipping macOS keychain extraction (test seam); cage starts with whatever credentials already exist, possibly none." >&2
    return 0
  fi
  # Guard: Docker creates a dir at this path if the file didn't exist on a prior failed mount
  if [[ -d "${HOME}/.claude/.credentials.json" ]]; then
    rmdir "${HOME}/.claude/.credentials.json" 2>/dev/null || \
      echo "Warning: ${HOME}/.claude/.credentials.json is a non-empty directory artifact — credentials will not be extracted" >&2
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    local creds_tmp creds_target
    creds_target="${HOME}/.claude/.credentials.json"
    creds_tmp=$(mktemp) || { echo "Warning: failed to create temp file for credentials extraction" >&2; return 1; }
    if security find-generic-password -s "Claude Code-credentials" -w > "$creds_tmp" 2>/dev/null; then
      # Write in place (truncate+write) to preserve the inode. Docker's single-file
      # bind mount on macOS tracks the original inode; mv (atomic rename) allocates
      # a new inode and silently breaks every already-mounted container's view of
      # this file. A non-atomic ~1 KB JSON write window is acceptable here.
      if [[ ! -e "$creds_target" ]]; then
        ( umask 077; : > "$creds_target" ) || {
          rm -f "$creds_tmp"
          echo "Warning: failed to create $creds_target" >&2
          return 1
        }
      fi
      if ! cat "$creds_tmp" > "$creds_target"; then
        rm -f "$creds_tmp"
        echo "Warning: failed to write credentials to $creds_target" >&2
        return 1
      fi
      chmod 600 "$creds_target" 2>/dev/null || true
      rm -f "$creds_tmp"
    else
      rm -f "$creds_tmp"
      # rip-cage-towm: only warn when there's no usable existing credential
      # file to fall back on. A usable file gets mounted regardless of this
      # extraction outcome, so the warning would be a false alarm — silent
      # here (info-level, not printed, to avoid adding routine noise on every
      # `rc up` for a host with no keychain item that's actually fine).
      if ! _extract_credentials_has_usable_existing; then
        echo "Warning: failed to extract Claude credentials from macOS keychain — fine if you are not using Claude Code in this cage" >&2
        echo "  If you are using Claude Code, run 'claude auth login' on the host to set up credentials, or set ANTHROPIC_API_KEY" >&2
      fi
      return 1
    fi
  fi
  return 0
}


cmd_auth() {
  case "${1:-}" in
    refresh) shift; cmd_auth_refresh "$@" ;;
    *) echo "Usage: rc auth refresh" >&2; exit 1 ;;
  esac
}


cmd_auth_refresh() {
  if [[ "$(uname)" != "Darwin" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      jq -nc '{"status": "ok", "action": "no_op", "message": "On Linux, update ~/.claude/.credentials.json directly."}'
    else
      echo "On Linux, update ~/.claude/.credentials.json directly." >&2
      echo "Running containers will see the change immediately via bind mount." >&2
    fi
    return 0
  fi
  if _extract_credentials; then
    # ADR-020 D6: refresh the identity-map cache timestamp so 24h TTL resets.
    # This prevents a cache miss on the next rc up immediately after auth refresh.
    _identity_cache_touch_all
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      jq -nc '{"status": "ok", "action": "credentials_refreshed", "credentials_updated": true}'
    else
      log "Credentials refreshed. Running containers will pick up the change on next API call."
    fi
  else
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Failed to extract credentials from macOS Keychain. Run 'claude auth login' first." "KEYCHAIN_EXTRACTION_FAILED"
    else
      echo "Error: Failed to extract credentials from macOS Keychain. Run 'claude auth login' first." >&2
      exit 1
    fi
  fi
}

