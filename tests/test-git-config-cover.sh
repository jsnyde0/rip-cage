#!/usr/bin/env bash
set -uo pipefail

# tests/test-git-config-cover.sh -- host-tier proof for rip-cage-rsh9.2
# (ADR-002 D11 evolved 2026-10-16): every git repo inside a read-write mount
# of the cage config gets its .git pinned and its config, info and hooks
# mounted read-only -- not only the repo `rc up` was pointed at.
#
#   G1  rc up --dry-run exits 0 with a config mounting two repos plus a tree
#       holding a nested repo and a submodule gitdir
#   G2  the workspace repo: pin + config/info/hooks ro, in the msb argv
#   G3  the second mounted repo gets the same covers (the old hooks cover
#       only ever saw the rc up argument)
#   G4  a repo one level down a mounted tree is covered
#   G5  a submodule gitdir under .git/modules is covered
#   G6  a repo under a read-only mount gets no cover (already read-only)
#   G7  each pin precedes the covers nested inside it in the argv
#   G8  the covers follow the config's mounts: a config that mounts another
#       repo at /workspace covers that repo, not the rc up argument
#   G9  no mutating runtime call
#
# Every `rc up` is --dry-run behind fake docker + msb PATH shims under a temp
# HOME (same idiom as tests/test-net-strict-default.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
TEMPLATE="${REPO_ROOT}/share/rip-cage/cage.yaml.template"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH (rc's config reads need it)"; exit 0; }

DUMMY_TOKEN="sk-ant-oatodJFCrnl2edlBDdz1C5Jau2RJtBRnlWmTSHf6pWkLUyifDLkDmWJ6UuVTAIjvFu7WICPhDeOZIiBOB-Y6sHrFH2ZUCr-lgotu2iX"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
T=$(_host_scratch_mktemp_d rc-git-cover)
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
OTHER="${T}/other"
TREE="${T}/tree"
ROREPO="${T}/rorepo"
mkdir -p "$H/.claude/projects" "$H/.claude/sessions" "$H/.config/rip-cage/secrets"
echo '{}' > "$H/.claude.json"
printf '%s' "$DUMMY_TOKEN" > "$H/.config/rip-cage/secrets/CCTOK"
chmod 600 "$H/.config/rip-cage/secrets/CCTOK"
[[ -e "${HOME}/.docker" ]] && ln -sfn "${HOME}/.docker" "${H}/.docker"

for _r in "$WS" "$OTHER" "${TREE}/pkg" "$ROREPO"; do
  mkdir -p "$_r" && git -C "$_r" init -q
done
# A submodule gitdir, as `git submodule add` lays it out.
mkdir -p "${WS}/.git/modules/vendor/lib"
cp "${WS}/.git/config" "${WS}/.git/modules/vendor/lib/config"
mkdir -p "${WS}/.git/modules/vendor/lib/hooks"

CONF="${T}/cage.yaml"
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${H}#g" \
    -e "s#<CAGE-NAME>#rsh92-test#g" \
    -e "s#^  - \"${WS}:/workspace\"#&\\
  - \"${OTHER}:/other\"\\
  - \"${TREE}:/tree\"\\
  - \"${ROREPO}:/rorepo:ro\"#" \
    "$TEMPLATE" > "$CONF"

_dry_run() {
  : > "$CALL_LOG"
  OUT=$(HOME="$H" XDG_CONFIG_HOME="${H}/.config" RC_CAGE_CONF="$1" PATH="${BIN}:${PATH}" \
        bash "$RC" up --dry-run "$@" 2>&1 </dev/null)
  RCODE=$?
}

_dry_run "$CONF" "$WS"
if [[ $RCODE -eq 0 ]]; then pass "G1 rc up --dry-run exits 0"; else fail "G1 rc up --dry-run exit ${RCODE}: $(tail -5 <<<"$OUT")"; fi
ARGV=$(grep '^Would run: ' <<<"$OUT" | head -1)
[[ -n "$ARGV" ]] || fail "G1 no 'Would run:' line in the dry-run output"

_has() { grep -qF -- "-v $1" <<<"$ARGV"; }
_covered() {  # <label> <host gitdir> <guest gitdir>
  local _l="$1" _h="$2" _g="$3" _miss=""
  _has "${_h}:${_g} " || _miss+=" pin"
  _has "${_h}/config:${_g}/config:ro" || _miss+=" config"
  _has "${_h}/info:${_g}/info:ro" || [[ ! -d "${_h}/info" ]] || _miss+=" info"
  _has "${_h}/hooks:${_g}/hooks:ro" || _miss+=" hooks"
  if [[ -z "$_miss" ]]; then pass "$_l"; else fail "$_l -- missing:${_miss}"; fi
}

_covered "G2 workspace repo: .git pinned, config/info/hooks read-only" "${WS}/.git" "/workspace/.git"
_covered "G3 second mounted repo gets the same covers" "${OTHER}/.git" "/other/.git"
_covered "G4 a repo one level down a mounted tree is covered" "${TREE}/pkg/.git" "/tree/pkg/.git"
_covered "G5 a submodule gitdir under .git/modules is covered" "${WS}/.git/modules/vendor/lib" "/workspace/.git/modules/vendor/lib"

if grep -qF "${ROREPO}/.git" <<<"$ARGV"; then fail "G6 a repo under a read-only mount got a cover"; else pass "G6 a repo under a read-only mount gets no cover"; fi

# G7: argv order -- the pin is a mount the covers nest inside.
_pos() { tr ' ' '\n' <<<"$ARGV" | grep -nxF -- "$1" | head -1 | cut -d: -f1; }
P_PIN=$(_pos "${WS}/.git:/workspace/.git"); P_CFG=$(_pos "${WS}/.git/config:/workspace/.git/config:ro")
if [[ -n "$P_PIN" && -n "$P_CFG" && "$P_PIN" -lt "$P_CFG" ]]; then pass "G7 the .git pin precedes the config cover nested in it"; else fail "G7 pin at '${P_PIN}', config cover at '${P_CFG}'"; fi

# G8: the covers follow the config's mounts, not the rc up argument. Here the
# argument is a repo the config does not mount; the tree it does mount at
# /workspace is the one covered.
CONF_OTHER="${T}/cage-other.yaml"
sed -e "s#^  - \"${WS}:/workspace\"#  - \"${OTHER}:/workspace\"#" -e "\#^  - \"${OTHER}:/other\"#d" "$CONF" > "$CONF_OTHER"
_dry_run "$CONF_OTHER" "$WS"
ARGV=$(grep '^Would run: ' <<<"$OUT" | head -1)
if [[ -n "$ARGV" ]] && _has "${OTHER}/.git/config:/workspace/.git/config:ro" && ! grep -qF "${WS}/.git" <<<"$ARGV"; then
  pass "G8 covers follow the config's mounts: /workspace is ${OTHER}'s repo, the unmounted rc up argument gets none"
else
  fail "G8 covers with the rc up argument unmounted (rc ${RCODE}): $(tail -3 <<<"$OUT")"
fi

if grep -Eq '^(docker (save|tag|pull|build|image load)|msb (load|create|pull|image load))' "$CALL_LOG"; then
  fail "G9 dry-run reached a mutating runtime call: $(grep -E '^(docker|msb) ' "$CALL_LOG" | head -3 | tr '\n' ';')"
else
  pass "G9 call log holds no save/tag/pull/load/create"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then echo "All tests passed."; exit 0; fi
echo "${FAILURES} test(s) failed."
exit 1
