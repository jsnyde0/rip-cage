#!/usr/bin/env bash
# codex-secret.sh — host-side helper for in-cage pi on the OpenAI (ChatGPT)
# subscription, provider openai-codex. Run it ON THE HOST, before `rc up`.
#
# It does two things, and touches nothing inside any cage:
#
#   1. Copies the CURRENT openai-codex access token out of the host pi's
#      auth.json into ~/.config/rip-cage/secrets/CODEX (0600). rc reads that
#      file at every `rc up` and msb injects the value on the wire toward
#      chatgpt.com. The guest never holds it.
#   2. Writes a PLACEHOLDER auth.json for the guest at
#      ~/.config/rip-cage/pi-codex/auth.json and prints the placeholder token
#      for the cage config's `secrets: CODEX: placeholder:` line. The
#      placeholder is a fake JWT (alg none) whose payload carries only your
#      ChatGPT account id: pi decodes the token in-process to read that id, so
#      a plain "$" + "MSB_CODEX" placeholder fails. Its `expires` is far in the
#      future, so guest pi never tries to refresh.
#
# FRESHNESS. The host pi keeps the real token fresh (it refreshes when you use
# openai-codex on the host). The secrets file is as fresh as your last run of
# this script; the access token lives ~10 days. Re-run it, then
# `rc up <project>` (a resume re-reads the file), whenever the cage gets a 401
# from chatgpt.com. rc never refreshes the token itself.
#
# Usage: codex-secret.sh [--print-placeholder]
#   --print-placeholder  print the placeholder token only; write nothing.
# Env:   PI_AUTH (default: ${PI_CODING_AGENT_DIR:-~/.pi/agent}/auth.json)
set -euo pipefail

_auth="${PI_AUTH:-${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}/auth.json}"
_rc_conf_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage"
_secret_file="${_rc_conf_dir}/secrets/CODEX"
_guest_auth="${_rc_conf_dir}/pi-codex/auth.json"
# 2100-01-01T00:00:00Z: past any cage's lifetime, so guest pi never refreshes.
_far_exp=4102444800

die() { echo "codex-secret: $*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"
[[ -r "$_auth" ]] || die "no readable pi auth file at ${_auth} — run 'pi' on the host and /login to the OpenAI (ChatGPT) subscription first"

_access=$(jq -r '."openai-codex".access // empty' "$_auth")
[[ -n "$_access" ]] || die "${_auth} has no openai-codex login — run 'pi' on the host and /login to it first"

# base64url-decode the JWT payload (segment 2) without printing the token.
_payload_seg=$(cut -d. -f2 <<<"$_access" | tr '_-' '/+')
while (( ${#_payload_seg} % 4 )); do _payload_seg+="="; done
_payload=$(base64 -d <<<"$_payload_seg" 2>/dev/null) || die "openai-codex access token is not a JWT"

_account=$(jq -r '."https://api.openai.com/auth".chatgpt_account_id // empty' <<<"$_payload")
[[ -n "$_account" ]] || die "openai-codex access token carries no chatgpt_account_id claim"
_exp=$(jq -r '.exp // 0' <<<"$_payload")

b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }
_header=$(printf '%s' '{"alg":"none","typ":"JWT"}' | b64url)
_body=$(jq -cn --arg a "$_account" --argjson e "$_far_exp" \
  '{iss: "rc-placeholder", exp: $e, "https://api.openai.com/auth": {chatgpt_account_id: $a}}' | b64url)
_placeholder="${_header}.${_body}.rc-placeholder"

if [[ "${1:-}" == "--print-placeholder" ]]; then
  printf '%s\n' "$_placeholder"
  exit 0
fi

_now=$(date +%s)
if (( _exp <= _now )); then
  die "the host openai-codex token expired at $(date -d "@${_exp}" 2>/dev/null || echo "${_exp}") — run 'pi' on the host once with --provider openai-codex so it refreshes, then re-run this script"
fi

umask 077
mkdir -p "$(dirname "$_secret_file")" "$(dirname "$_guest_auth")"
printf '%s' "$_access" > "${_secret_file}.tmp" && mv "${_secret_file}.tmp" "$_secret_file"
jq -n --arg p "$_placeholder" --argjson ms "$(( _far_exp * 1000 ))" \
  '{"openai-codex": {type: "oauth", access: $p, refresh: "rc-placeholder-no-refresh", expires: $ms}}' \
  > "${_guest_auth}.tmp" && mv "${_guest_auth}.tmp" "$_guest_auth"
chmod 0444 "$_guest_auth"

echo "codex-secret: wrote ${_secret_file} (real token, expires $(date -d "@${_exp}" -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo "${_exp}"))"
echo "codex-secret: wrote ${_guest_auth} (placeholder only; mount it :ro at /home/agent/.pi/agent/auth.json)"
echo "codex-secret: placeholder for the cage config's secrets.CODEX.placeholder:"
printf '%s\n' "$_placeholder"
