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
#   G10 a nested submodule gitdir (.git/modules/<a>/modules/<b>) is covered
#   G11 config.worktree is ro, for the main gitdir and a linked worktree
#   G12 a linked worktree's commondir is ro (it redirects the config)
#   G13 submodule .git files are ro: one the scan finds, ones past the scan
#       depth that only .gitmodules names, and a nested one
#   G14 a branch named `config` in a submodule gitdir gets no refs/heads pin
#   G15 a repo under a ro mount nested inside a rw one gets no cover (a rw
#       pin would re-expose it)
#   G16 extensions.worktreeConfig=true with no config.worktree refuses
#   G17 worktree mode: the main .git rc mounts gets the same ro covers, and
#       rc's own /workspace/.git gitfile is the only mount there
#   G18 worktree mode refuses, visibly, a missing config.worktree
#
# G10-G18 fail on 12dd2bc (review findings 1, 2, 3, 5 on rip-cage-rsh9.2).
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

for _r in "$WS" "$OTHER" "${TREE}/pkg" "${TREE}/ropkg" "$ROREPO"; do
  mkdir -p "$_r" && git -C "$_r" init -q
done
_git() { git -c user.email=t@t -c user.name=t -c protocol.file.allow=always "$@"; }
# Real submodules: src-lib carries its own submodule `inner`, so the
# workspace gets a nested submodule gitdir (.git/modules/vendor/lib/modules/
# inner) and nested .git files. lib0's .git file sits inside the scan depth;
# vendor/lib's and deep/x/y/lib2's lie past it, so only .gitmodules finds them.
SRC="${T}/src"
mkdir -p "${SRC}/inner" "${SRC}/lib"
git -C "${SRC}/inner" init -q && _git -C "${SRC}/inner" commit -q --allow-empty -m i
git -C "${SRC}/lib" init -q && _git -C "${SRC}/lib" submodule add -q "${SRC}/inner" inner && _git -C "${SRC}/lib" commit -q -m l
_git -C "$WS" commit -q --allow-empty -m init
for _p in lib0 vendor/lib deep/x/y/lib2; do _git -C "$WS" submodule add -q "${SRC}/lib" "$_p"; done
_git -C "$WS" submodule update -q --init --recursive
_git -C "$WS" commit -q -m subs
# A branch named `config` inside a submodule gitdir: a file called config
# under refs/, which is no gitdir.
_git -C "${WS}/lib0" branch config
# A linked worktree (gitdir .git/worktrees/wt-out, holding commondir) and
# extensions.worktreeConfig with a config.worktree for main and linked.
_git -C "$WS" worktree add -q "${T}/wt-out" -b wtb
git -C "$WS" config extensions.worktreeConfig true
git -C "$WS" config --worktree rc.test main
git -C "${T}/wt-out" config --worktree rc.test linked

CONF="${T}/cage.yaml"
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${H}#g" \
    -e "s#<CAGE-NAME>#rsh92-test#g" \
    -e "s#^  - \"${WS}:/workspace\"#&\\
  - \"${OTHER}:/other\"\\
  - \"${TREE}:/tree\"\\
  - \"${TREE}/ropkg:/tree/ropkg:ro\"\\
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

_covered "G10 a nested submodule gitdir (.git/modules/vendor/lib/modules/inner) is covered" \
  "${WS}/.git/modules/vendor/lib/modules/inner" "/workspace/.git/modules/vendor/lib/modules/inner"

_ro_all() {  # <label> <host:guest>... -- each must be in the argv as :ro
  local _l="$1" _miss=""; shift
  local _m; for _m in "$@"; do _has "${_m}:ro" || _miss+=" ${_m}"; done
  if [[ -z "$_miss" ]]; then pass "$_l"; else fail "$_l -- missing:${_miss}"; fi
}
_ro_all "G11 config.worktree is read-only, main and linked worktree" \
  "${WS}/.git/config.worktree:/workspace/.git/config.worktree" \
  "${WS}/.git/worktrees/wt-out/config.worktree:/workspace/.git/worktrees/wt-out/config.worktree"
_ro_all "G12 a linked worktree's commondir is read-only" \
  "${WS}/.git/worktrees/wt-out/commondir:/workspace/.git/worktrees/wt-out/commondir"
_ro_all "G13 submodule .git files are read-only: in the scan depth, past it, and nested" \
  "${WS}/lib0/.git:/workspace/lib0/.git" \
  "${WS}/vendor/lib/.git:/workspace/vendor/lib/.git" \
  "${WS}/deep/x/y/lib2/.git:/workspace/deep/x/y/lib2/.git" \
  "${WS}/vendor/lib/inner/.git:/workspace/vendor/lib/inner/.git"

if grep -qF "/refs/heads:" <<<"$ARGV"; then fail "G14 a branch named config got a refs/heads pin"; else pass "G14 a branch named config under a submodule gitdir gets no pin"; fi

if grep -qF "${TREE}/ropkg/.git" <<<"$ARGV"; then fail "G15 a repo under a nested read-only mount got a (re-exposing) cover"; else pass "G15 a repo under a read-only mount nested in a rw one gets no cover"; fi

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

# G16: extensions.worktreeConfig=true with no config.worktree -- a file the
# guest could create, which no mount can cover -- refuses the launch.
REF="${T}/refrepo"
mkdir -p "$REF" && git -C "$REF" init -q && git -C "$REF" config extensions.worktreeConfig true
CONF_REF="${T}/cage-ref.yaml"
sed -e "s#^  - \"${WS}:/workspace\"#  - \"${REF}:/workspace\"#" "$CONF" > "$CONF_REF"
_dry_run "$CONF_REF" "$WS"
if [[ $RCODE -ne 0 ]] && grep -qF "${REF}/.git/config.worktree" <<<"$OUT" && ! grep -q '^Would run: ' <<<"$OUT"; then
  pass "G16 worktreeConfig=true with config.worktree missing refuses, naming the file"
else
  fail "G16 worktreeConfig refusal (rc ${RCODE}): $(tail -3 <<<"$OUT")"
fi

# G17: worktree mode -- rc up on the linked worktree. rc mounts the main .git
# at /workspace/.git-main itself, so its config sources are covered there; the
# host's /workspace/.git gitfile cover gives way to rc's own corrected one.
CONF_WT="${T}/cage-wt.yaml"
sed -e "s#^  - \"${WS}:/workspace\"#  - \"${T}/wt-out:/workspace\"#" "$CONF" > "$CONF_WT"
_dry_run "$CONF_WT" "${T}/wt-out"
ARGV=$(grep '^Would run: ' <<<"$OUT" | head -1)
_miss=""
_has "${WS}/.git:/workspace/.git-main " || _miss+=" .git-main"
for _m in config config.worktree hooks worktrees/wt-out/commondir worktrees/wt-out/config.worktree; do
  _has "${WS}/.git/${_m}:/workspace/.git-main/${_m}:ro" || _miss+=" ${_m}"
done
_n=$(tr ' ' '\n' <<<"$ARGV" | grep -c -- ':/workspace/.git:ro$')
_has "${T}/wt-out/.git:/workspace/.git:ro" && _miss+=" host-gitfile-cover-not-dropped"
if [[ $RCODE -eq 0 && -z "$_miss" && "$_n" -eq 1 ]]; then
  pass "G17 worktree mode: main .git's config sources ro at /workspace/.git-main, one /workspace/.git mount (rc's)"
else
  fail "G17 worktree mode (rc ${RCODE}, /workspace/.git mounts: ${_n}) -- missing:${_miss} $(tail -3 <<<"$OUT")"
fi

# G18: worktree mode, worktreeConfig=true, no config.worktree anywhere: the
# refusal reaches stderr (the dry-run mount preview silences its own).
REF2="${T}/ref2"
mkdir -p "$REF2" && git -C "$REF2" init -q && _git -C "$REF2" commit -q --allow-empty -m init
_git -C "$REF2" worktree add -q "${T}/ref2-wt" -b r2
git -C "$REF2" config extensions.worktreeConfig true
CONF_WT2="${T}/cage-wt2.yaml"
sed -e "s#^  - \"${WS}:/workspace\"#  - \"${T}/ref2-wt:/workspace\"#" "$CONF" > "$CONF_WT2"
_dry_run "$CONF_WT2" "${T}/ref2-wt"
if [[ $RCODE -ne 0 ]] && grep -qF "${REF2}/.git/worktrees/ref2-wt/config.worktree" <<<"$OUT" && ! grep -q '^Would run: ' <<<"$OUT"; then
  pass "G18 worktree mode refuses a missing config.worktree under worktreeConfig, visibly"
else
  fail "G18 worktree-mode refusal (rc ${RCODE}): $(tail -3 <<<"$OUT")"
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
