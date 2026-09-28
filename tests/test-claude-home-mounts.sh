#!/usr/bin/env bash
set -uo pipefail

# tests/test-claude-home-mounts.sh -- host-tier proof for rip-cage-mxr8: the
# Claude-home mounts are split between the cage config and rc, and never
# declared by both.
#
#   projects / sessions -- the CONFIG owns them; rc appends neither.
#   skills              -- RC owns them (the .rc-context/skills projection
#                          plus init's symlink); the template carries no line.
#
# msb refuses two mounts on one guest path, so the union of the config's
# mounts and rc's generated -v flags must name each guest path at most once.
# That union is what this file checks, on the shipped template verbatim with
# its placeholders filled.
#
# Every `rc up` here is --dry-run AND runs behind fake docker + msb PATH shims
# that log every call (same idiom as tests/test-auth-secret.sh), under a temp
# HOME and XDG_CONFIG_HOME. The call log is asserted to hold no
# save/tag/pull/load/create line, so this file cannot touch a real image.

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

T=$(mktemp -d /private/tmp/rc-claude-home-mounts-XXXXXX)
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
mkdir -p "$H/.claude/skills/demo" "$WS" "$H/.config/rip-cage/secrets"
echo '{}' > "$H/.claude.json"
printf '%s' "$DUMMY_TOKEN" > "$H/.config/rip-cage/secrets/CCTOK"
chmod 600 "$H/.config/rip-cage/secrets/CCTOK"
[[ -e "${HOME}/.docker" ]] && ln -sfn "${HOME}/.docker" "${H}/.docker"

# _conf_from_template OUT [extra sed args...] -- the template with its
# placeholders filled, then any extra sed edits.
_conf_from_template() {
  local _out="$1"; shift
  sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
      -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${H}#g" \
      -e "s#<CAGE-NAME>#mxr8-test#g" \
      "$@" "$TEMPLATE" > "$_out"
}

# _dry_run CONF -> sets OUT (stdout+stderr) and RCODE.
_dry_run() {
  : > "$CALL_LOG"
  OUT=$(HOME="$H" XDG_CONFIG_HOME="${H}/.config" RC_CAGE_CONF="$1" PATH="${BIN}:${PATH}" \
        bash "$RC" up --dry-run "$WS" 2>&1 </dev/null)
  RCODE=$?
}

# _guest_paths CONF -- every guest path msb would see: the config's string
# mounts, its map-form targets, and each -v target on the "Would run:" argv.
_guest_paths() {
  local _conf="$1"
  yq -r '.mounts // [] | .[] | select(tag == "!!str")' "$_conf" | awk -F: '{print $2}'
  yq -r '.mounts // [] | .[] | select(tag == "!!map") | .target // ""' "$_conf"
  grep '^Would run: msb create' <<<"$OUT" | tr ' ' '\n' \
    | awk 'prev == "-v" { split($0, a, ":"); print a[2] } { prev = $0 }'
}

_no_side_effects() {
  if grep -Eq '^(docker (save|tag|pull|build|image load)|msb (load|create|pull|image load))' "$CALL_LOG"; then
    fail "$1: dry-run reached a mutating runtime call: $(grep -E '^(docker (save|tag|pull|build)|msb (load|create|pull))' "$CALL_LOG" | head -3 | tr '\n' ';')"
  else
    pass "$1: call log holds no save/tag/pull/load/create"
  fi
}

# =============================================================================
# (a) the shipped template, placeholders filled, verbatim
# =============================================================================
echo "=== (a) template verbatim ==="
if grep -q '/.claude/skills:/home/agent/.claude/skills' "$TEMPLATE"; then
  fail "(a) template still mounts ~/.claude/skills (rc owns that projection)"
else
  pass "(a) template carries no ~/.claude/skills mount line"
fi
CONF_A="${T}/a.yaml"
_conf_from_template "$CONF_A"
_dry_run "$CONF_A"
if [[ $RCODE -eq 0 ]]; then pass "(a) rc up --dry-run exits 0"; else fail "(a) rc up --dry-run exit ${RCODE}: $(tail -5 <<<"$OUT")"; fi
if grep -q '^Would run: msb create' <<<"$OUT"; then
  pass "(a) dry-run printed the exact msb create argv"
else
  fail "(a) no 'Would run: msb create' argv line: $(tail -5 <<<"$OUT")"
fi
dups=$(_guest_paths "$CONF_A" | grep -v '^$' | sort | uniq -d)
if [[ -z "$dups" ]]; then
  pass "(a) config + argv name each guest path at most once"
else
  fail "(a) duplicate guest paths (msb refuses these): ${dups//$'\n'/ }"
fi
for _p in /home/agent/.claude/projects /home/agent/.claude/sessions; do
  n=$(_guest_paths "$CONF_A" | grep -cxF "$_p")
  if [[ "$n" -eq 1 ]]; then pass "(a) ${_p} mounted exactly once"; else fail "(a) ${_p} mounted ${n} times"; fi
done
if grep -q '/home/agent/.rc-context/skills:ro' <<<"$OUT"; then
  pass "(a) rc still projects host skills at /home/agent/.rc-context/skills"
else
  fail "(a) rc's skills projection missing from the argv"
fi
if grep -q 'does not mount ~/.claude\|mounts ~/.claude/skills itself' <<<"$OUT"; then
  fail "(a) a Claude-home mount warning fired on the template: $(grep 'Warning: cage config' <<<"$OUT" | head -2)"
else
  pass "(a) no Claude-home mount warning on the template"
fi
_no_side_effects "(a)"

# =============================================================================
# (b) a config WITHOUT the two session lines: boots (dry-run 0) and warns,
#     naming each line to add
# =============================================================================
echo ""
echo "=== (b) config missing the session lines ==="
CONF_B="${T}/b.yaml"
_conf_from_template "$CONF_B" \
  -e '\#/.claude/projects:/home/agent/.claude/projects"#d' \
  -e '\#/.claude/sessions:/home/agent/.claude/sessions"#d'
_dry_run "$CONF_B"
if [[ $RCODE -eq 0 ]]; then pass "(b) rc up --dry-run still exits 0 (warn, never refuse)"; else fail "(b) exit ${RCODE}"; fi
for _sub in projects sessions; do
  if grep -qF "does not mount ~/.claude/${_sub}" <<<"$OUT" \
      && grep -qF "\"${H}/.claude/${_sub}:/home/agent/.claude/${_sub}\"" <<<"$OUT"; then
    pass "(b) warning names the missing ~/.claude/${_sub} line"
  else
    fail "(b) no warning naming ~/.claude/${_sub}: $(grep -i warning <<<"$OUT" | head -3)"
  fi
done
n=$(_guest_paths "$CONF_B" | grep -cxF /home/agent/.claude/projects)
if [[ "$n" -eq 0 ]]; then pass "(b) rc added no projects mount of its own"; else fail "(b) rc still appends a projects mount (${n})"; fi
_no_side_effects "(b)"

# =============================================================================
# (c) a PRE-mxr8 config still carrying the old skills line: warned before msb
# =============================================================================
echo ""
echo "=== (c) config carrying the legacy skills line ==="
CONF_C="${T}/c.yaml"
_conf_from_template "$CONF_C" \
  -e "s#^  - \"${WS}:/workspace\"#&\\
  - \"${H}/.claude/skills:/home/agent/.claude/skills:ro\"#"
if ! grep -qF "${H}/.claude/skills:/home/agent/.claude/skills:ro" "$CONF_C"; then
  fail "(c) fixture: legacy skills line was not inserted"
fi
_dry_run "$CONF_C"
if [[ $RCODE -eq 0 ]]; then pass "(c) rc up --dry-run exits 0"; else fail "(c) exit ${RCODE}"; fi
if grep -qF "mounts ~/.claude/skills itself" <<<"$OUT"; then
  pass "(c) warning names the config's ~/.claude/skills line"
else
  fail "(c) no warning about the legacy skills line: $(grep -i warning <<<"$OUT" | head -3)"
fi
_no_side_effects "(c)"

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
[[ $FAILURES -eq 0 ]]
