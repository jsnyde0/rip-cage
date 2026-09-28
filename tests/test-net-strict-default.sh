#!/usr/bin/env bash
set -uo pipefail

# tests/test-net-strict-default.sh -- host-tier proof for rip-cage-q146: msb
# 0.7.3 flipped network.strict's default to true. Under strict, a
# hostname-allowed HTTPS request needs TLS interception, which msb turns on
# while a secret is bound. Measured: the template (CCTOK bound) works; the
# same config with no secrets loses every allowed HTTPS host.
#
#   (a) the shipped template: no strict line, CCTOK bound, no warning
#   (b) the template with its secrets block removed: rc up still exits 0 and
#       warns, naming the line to add (strict: false)
#   (c) no secrets, strict: false set: no warning
#   (d) no secrets, strict: true chosen on purpose: no warning
#
# Every `rc up` here is --dry-run behind fake docker + msb PATH shims under a
# temp HOME (same idiom as tests/test-claude-home-mounts.sh); the call log is
# asserted to hold no save/tag/pull/load/create line.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
TEMPLATE="${REPO_ROOT}/share/rip-cage/cage.yaml.template"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH (rc's config reads need it)"; exit 0; }

# Same dummy setup-token shape as tests/test-auth-secret.sh; never a real one.
DUMMY_TOKEN="sk-ant-oatodJFCrnl2edlBDdz1C5Jau2RJtBRnlWmTSHf6pWkLUyifDLkDmWJ6UuVTAIjvFu7WICPhDeOZIiBOB-Y6sHrFH2ZUCr-lgotu2iX"

T=$(mktemp -d /private/tmp/rc-net-strict-XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

CALL_LOG="${T}/calls.log"
BIN="${T}/bin"
mkdir -p "$BIN"
for _tool in docker msb; do
  cat > "${BIN}/${_tool}" <<FAKEEOF
#!/usr/bin/env bash
echo "${_tool} \$*" >> "${CALL_LOG}"
exit 0
FAKEEOF
  chmod +x "${BIN}/${_tool}"
done

H="${T}/home"
WS="${T}/ws"
mkdir -p "$H/.claude/projects" "$H/.claude/sessions" "$WS" "$H/.config/rip-cage/secrets"
echo '{}' > "$H/.claude.json"
printf '%s' "$DUMMY_TOKEN" > "$H/.config/rip-cage/secrets/CCTOK"
chmod 600 "$H/.config/rip-cage/secrets/CCTOK"
[[ -e "${HOME}/.docker" ]] && ln -sfn "${HOME}/.docker" "${H}/.docker"

_conf_from_template() {
  local _out="$1"; shift
  sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
      -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${H}#g" \
      -e "s#<CAGE-NAME>#q146-test#g" \
      "$@" "$TEMPLATE" > "$_out"
}

_dry_run() {
  : > "$CALL_LOG"
  OUT=$(HOME="$H" XDG_CONFIG_HOME="${H}/.config" RC_CAGE_CONF="$1" PATH="${BIN}:${PATH}" \
        bash "$RC" up --dry-run "$WS" 2>&1 </dev/null)
  RCODE=$?
}

_no_side_effects() {
  if grep -Eq '^(docker (save|tag|pull|build|image load)|msb (load|create|pull|image load))' "$CALL_LOG"; then
    fail "$1: dry-run reached a mutating runtime call: $(grep -E '^(docker|msb) ' "$CALL_LOG" | head -3 | tr '\n' ';')"
  else
    pass "$1: call log holds no save/tag/pull/load/create"
  fi
}

WARN='binds no secret and does not set network.strict'
# The template's secrets block runs from `secrets:` to the blank line after
# its env: entry; drop both keys for the no-secret shape.
NOSECRET_SED=(-e '/^secrets:$/,/^env:$/d' -e '/^  CLAUDE_CODE_OAUTH_TOKEN:/d')

echo "=== (a) template verbatim ==="
if [[ "$(yq -r '.network.strict' "$TEMPLATE")" == "null" && "$(yq -r '.secrets | length' "$TEMPLATE")" -ge 1 ]]; then
  pass "(a) template leaves strict at msb's default and binds a secret"
else
  fail "(a) template strict='$(yq -r '.network.strict' "$TEMPLATE")' secrets=$(yq -r '.secrets | length' "$TEMPLATE")"
fi
CONF_A="${T}/a.yaml"
_conf_from_template "$CONF_A"
_dry_run "$CONF_A"
if [[ $RCODE -eq 0 ]]; then pass "(a) rc up --dry-run exits 0"; else fail "(a) rc up --dry-run exit ${RCODE}: $(tail -5 <<<"$OUT")"; fi
if grep -qF "$WARN" <<<"$OUT"; then fail "(a) strict warning fired on the template"; else pass "(a) no strict warning on the template"; fi
_no_side_effects "(a)"

echo ""
echo "=== (b) no secrets, strict unset ==="
CONF_B="${T}/b.yaml"
_conf_from_template "$CONF_B" "${NOSECRET_SED[@]}"
if [[ "$(yq -r '.secrets // {} | length' "$CONF_B")" == "0" && "$(yq -r '.network.strict' "$CONF_B")" == "null" && "$(yq -r '.env // {} | length' "$CONF_B")" == "0" ]]; then
  pass "(b) fixture binds no secret, sets no strict, keeps no env"
else
  fail "(b) fixture still carries secrets/env/strict"
fi
_dry_run "$CONF_B"
if [[ $RCODE -eq 0 ]]; then pass "(b) rc up --dry-run still exits 0 (warn-only)"; else fail "(b) rc up --dry-run exit ${RCODE}: $(tail -5 <<<"$OUT")"; fi
if grep -F "$WARN" <<<"$OUT" | grep -qF 'strict: false'; then
  pass "(b) rc up warns and names the line: strict: false"
else
  fail "(b) strict warning absent or does not name the line: $(grep -i strict <<<"$OUT" | head -2)"
fi
_no_side_effects "(b)"

for _case in "c:false" "d:true"; do
  _k="${_case%%:*}"; _v="${_case#*:}"
  echo ""
  echo "=== (${_k}) no secrets, strict: ${_v} ==="
  _c="${T}/${_k}.yaml"
  _conf_from_template "$_c" "${NOSECRET_SED[@]}" -e "s/^  policy: none$/&\\
  strict: ${_v}/"
  if [[ "$(yq -r '.network.strict' "$_c")" == "$_v" ]]; then pass "(${_k}) fixture sets strict: ${_v}"; else fail "(${_k}) fixture strict='$(yq -r '.network.strict' "$_c")'"; fi
  _dry_run "$_c"
  if [[ $RCODE -eq 0 ]]; then pass "(${_k}) rc up --dry-run exits 0"; else fail "(${_k}) rc up --dry-run exit ${RCODE}: $(tail -5 <<<"$OUT")"; fi
  if grep -qF "$WARN" <<<"$OUT"; then fail "(${_k}) strict warning fired although strict is set"; else pass "(${_k}) no strict warning when strict is set"; fi
  _no_side_effects "(${_k})"
done

echo ""
if [[ $FAILURES -eq 0 ]]; then echo "=== all passed ==="; exit 0; fi
echo "=== ${FAILURES} failed ==="
exit 1
