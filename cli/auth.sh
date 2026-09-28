#!/usr/bin/env bash
# cli/auth.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).
#
# rip-cage-ely4.7.17: the keychain -> mounted-credentials-file possession
# path (extract, mount read-write) is RETIRED, no fallback. The Claude login
# reaches the guest only via msb `--secret` non-possession (ADR-031 D1/D5(a)):
# the shipped template declares `secrets: CCTOK` bound to api.anthropic.com,
# `env: CLAUDE_CODE_OAUTH_TOKEN: "$MSB_CCTOK"`, and `_up_prepare_conf_secret_env`
# (cli/up.sh) reads the real value from
# $XDG_CONFIG_HOME/rip-cage/secrets/CCTOK. rip-cage-cmqb (closed, July)
# measured that the long-lived `claude setup-token` value is the only shape
# that survives a static --secret header swap -- a short-lived keychain
# access token cannot, because it depends on a refresh flow a placeholder
# cannot carry.
#
# `rc auth` therefore does ONE thing: check that the operator has already put
# a well-shaped token at that file. It never reads a keychain, never runs
# `claude setup-token` itself, and never prompts -- CLAUDE.md philosophy is
# agent-first / no human-in-the-loop prompts, and the one-time browser flow
# `claude setup-token` drives is exactly that kind of prompt. `rc auth
# refresh` is retired with the possession path it used to refresh (a
# short-lived token needed hot-swapping; a long-lived setup-token does not).

# Setup-token shape floor. `claude setup-token` prints a long-lived OAuth
# token with an "sk-ant-oat" prefix followed by ~108 characters drawn only
# from [A-Za-z0-9_-] (observed shape); real tokens run to ~118 characters
# total. 80 is chosen well below that observed length while staying far
# above anything a truncated paste, an accidental short string, or an empty
# placeholder would produce. Never used to validate anything but SHAPE --
# the actual value is never printed, logged, or compared against a
# known-good corpus (that would require reading a real token into a
# log/diff surface).
_AUTH_CCTOK_MIN_LEN=80

# _auth_cctok_file — echo the resolved host-side secret file path for the
# CCTOK secret (ADR-031 D5(a): host-side, outside every cage mount, never a
# path the cage config can point at). Same $XDG_CONFIG_HOME convention as
# _up_prepare_conf_secret_env (cli/up.sh) reads its value from -- one
# location, cited not reimplemented.
_auth_cctok_file() {
  echo "${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/secrets/CCTOK"
}

# _auth_file_mode FILE — echo FILE's permission bits as a bare octal string
# ("600"), portable across GNU stat (Linux) and BSD stat (macOS). Echoes
# nothing and returns non-zero if stat is unavailable or FILE vanished
# between the caller's existence check and this call.
#
# rip-cage-ely4.7.17 fix round 3, finding 1: GNU coreutils' `stat -f` is a
# DIFFERENT flag from BSD's -- "-f" means "report the FILESYSTEM, not the
# file" on GNU, so `stat -f '%Lp' FILE` there prints filesystem status to
# STDOUT and still exits 1 (wrong output, not a clean failure). The old
# `stat -f ... || stat -c ...` one-liner ran both on GNU (the `||` only
# short-circuits on the first's exit code) and its stdout was the
# CONCATENATION of the filesystem-status junk AND the real "600" -- which
# never string-equals "600", so `rc auth` and `rc up`'s gate failed on every
# Linux host. Each branch below is captured SEPARATELY and only returned on
# its OWN success, so the two invocations' stdout can never mix. GNU's -c
# form is tried first (this is the common case, Linux); BSD's `stat -c`
# fails fast with empty stdout and a non-zero exit, so the `&&` falls
# through to the BSD -f form cleanly.
_auth_file_mode() {
  local _mode
  if _mode=$(stat -c '%a' "$1" 2>/dev/null) && [[ -n "$_mode" ]]; then
    printf '%s' "$_mode"
    return 0
  fi
  if _mode=$(stat -f '%Lp' "$1" 2>/dev/null) && [[ -n "$_mode" ]]; then
    printf '%s' "$_mode"
    return 0
  fi
  return 1
}

# _auth_cctok_check — verify the CCTOK secret file: exists, is a regular
# file, mode EXACTLY 0600, readable, and holds a setup-token-shaped value:
# "sk-ant-oat" prefix, every character after it drawn only from
# [A-Za-z0-9_-] (rejects a pasted URL, quoted value, or "key=value" line --
# '.', '/', ':', '"', "'", '=' are all outside that charset), and total
# length >= _AUTH_CCTOK_MIN_LEN. A single trailing newline is tolerated --
# $(cat FILE) already strips exactly one before this function ever sees the
# value, matching how an operator's editor or `>` redirect would save it; a
# remaining embedded newline is a genuine second line and still malformed.
#
# NEVER prints, logs, or echoes the token value or any substring of it --
# existence/mode/shape verdict only, everywhere this function or its callers
# touch stdout/stderr.
#
# Sets _AUTH_CCTOK_REASON on failure to one of:
#   missing | not_regular_file | bad_mode | not_readable | empty | malformed
# Returns 0 (valid) or 1 (invalid, reason in _AUTH_CCTOK_REASON).
_auth_cctok_check() {
  local _file
  _file=$(_auth_cctok_file)
  _AUTH_CCTOK_REASON=""
  if [[ ! -e "$_file" ]]; then
    _AUTH_CCTOK_REASON="missing"
    return 1
  fi
  if [[ ! -f "$_file" ]]; then
    _AUTH_CCTOK_REASON="not_regular_file"
    return 1
  fi
  local _mode
  _mode=$(_auth_file_mode "$_file")
  if [[ "$_mode" != "600" ]]; then
    _AUTH_CCTOK_REASON="bad_mode"
    return 1
  fi
  if [[ ! -r "$_file" ]]; then
    _AUTH_CCTOK_REASON="not_readable"
    return 1
  fi
  local _value
  _value="$(cat "$_file" 2>/dev/null)"
  if [[ -z "$_value" ]]; then
    _AUTH_CCTOK_REASON="empty"
    return 1
  fi
  # $(...) already stripped a trailing newline; a REMAINING embedded newline
  # means a genuine second line, which is malformed for a one-line token file.
  if [[ "$_value" == *$'\n'* ]]; then
    _AUTH_CCTOK_REASON="malformed"
    return 1
  fi
  if [[ ! "$_value" =~ ^sk-ant-oat[A-Za-z0-9_-]*$ ]]; then
    _AUTH_CCTOK_REASON="malformed"
    return 1
  fi
  if [[ "${#_value}" -lt "$_AUTH_CCTOK_MIN_LEN" ]]; then
    _AUTH_CCTOK_REASON="malformed"
    return 1
  fi
  return 0
}

# _auth_cctok_fail_message REASON — the operator-facing remediation text for
# a _auth_cctok_check failure. Names the exact file path and the one-time
# human step; never the token value. One message home: shared verbatim by
# `rc auth` and the `rc up` pre-check (_up_check_cctok_secret, cli/up.sh) so
# the operator sees identical text no matter which command caught it.
_auth_cctok_fail_message() {
  local _reason="$1" _file
  _file=$(_auth_cctok_file)
  case "$_reason" in
    missing) echo "No Claude auth token found at ${_file}." ;;
    not_regular_file) echo "${_file} exists but is not a regular file." ;;
    bad_mode) echo "${_file} exists but is not mode 0600 (found $(_auth_file_mode "$_file" 2>/dev/null || echo '?'))." ;;
    not_readable) echo "${_file} exists but rc cannot read it." ;;
    empty) echo "${_file} exists but is empty." ;;
    malformed) echo "${_file} exists but does not hold a setup-token-shaped value ('sk-ant-oat' prefix, only [A-Za-z0-9_-] after it, at least ${_AUTH_CCTOK_MIN_LEN} characters total)." ;;
    *) echo "${_file}: auth check failed." ;;
  esac
  echo "One-time human step:"
  echo "  1. Run 'claude setup-token' in a terminal (prints a long-lived OAuth token)."
  echo "  2. Save the printed token to ${_file}"
  echo "  3. chmod 600 ${_file}"
  echo "To use ANTHROPIC_API_KEY instead, delete the secrets: CCTOK block and the CLAUDE_CODE_OAUTH_TOKEN env line from this cage's config."
}

# cmd_auth — bare `rc auth` only; any subcommand/arg is a usage error. The
# old hot-swap subcommand is retired with the possession path it served (a
# short-lived keychain token needed hot-swapping; the long-lived
# claude-setup-token value this checks does not).
cmd_auth() {
  if [[ $# -gt 0 ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Usage: rc auth (takes no subcommand or argument; it only checks the host CCTOK secrets file)" "AUTH_USAGE"
    fi
    echo "Usage: rc auth" >&2
    echo "  rc auth takes no subcommand or argument; it only checks the host CCTOK secrets file (ADR-031 D1/D5(a))." >&2
    exit 1
  fi
  if _auth_cctok_check; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      jq -nc --arg file "$(_auth_cctok_file)" '{"status": "ok", "file": $file}'
    else
      echo "OK — $(_auth_cctok_file) (0600, setup-token-shaped)"
    fi
    return 0
  fi
  local _msg
  _msg=$(_auth_cctok_fail_message "$_AUTH_CCTOK_REASON")
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    json_error "$_msg" "AUTH_CCTOK_INVALID"
  else
    echo "Error: Claude auth check failed." >&2
    echo "$_msg" >&2
    exit 1
  fi
}
