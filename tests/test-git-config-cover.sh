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
#   G16 extensions.worktreeConfig=true with no config.worktree: --dry-run
#       writes nothing, says "Would create", and previews the ro cover
#   G16c the same on the real path: created empty, one line says so, covered ro
#   G16b the same when rc cannot create it refuses, naming one touch command
#   G17 worktree mode: the main .git rc mounts gets the same ro covers, and
#       rc's own /workspace/.git gitfile is the only mount there
#   G18 worktree mode --dry-run: both missing config.worktree files are named,
#       neither is written, both covers are previewed
#   G20 config.worktree as a symlink (to /dev/null, dangling, to a file) or a
#       FIFO refuses, naming it, with no cover and nothing written through it
#   G21 a rw mount nested inside a ro one keeps its .git covers
#   G19 the .git scan reaches a repo at depth 4 when RC_PROTECTED_SCAN_DEPTH
#       is unset (and not at 2); a depth that is not a positive integer refuses
#
#   H1-H11 the nested-repo hide (rip-cage-rsh9.17.3.1, ADR-002 D11): the hide
#       line, own-line repos, ro own line, target-equal mounts, the two
#       refusals, allowed mounts, the tmpfs skip set, the nested-nested repo,
#       two guest paths, the classifier seam, the README dir. H12-H16 (fix round):
#       volume targets in the deepest-mount rule and refusal (a), a FIFO inside
#       a hide, the protected-paths JSON code, a pointer-file repo under a tmpfs,
#       and rc's own generated mounts dropped inside a hide. G4 now expects a
#       hide, not covers.
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
# inner) and nested .git files. The scan is capped at depth 2 below (the
# default is unlimited) so lib0's .git file sits inside it while vendor/lib's
# and deep/x/y/lib2's lie past it, and only .gitmodules finds them.
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
  OUT=$(HOME="${RUN_HOME:-$H}" XDG_CONFIG_HOME="${H}/.config" RC_CAGE_CONF="$1" RC_PROTECTED_SCAN_DEPTH="${SCAN_DEPTH-2}" PATH="${BIN}:${PATH}" \
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
HIDE_SRC="${H}/.cache/rc/hidden-repo"
_under() {  # <guest path> [self-tmpfs] -- argv tokens at or under it; with a 2nd arg, the one --tmpfs token AT the path itself is not counted
  tr ' ' '\n' <<<"$ARGV" | awk -v p="$1" -v nt="${2:-}" '{ g = $0; if (index(g, ":")) { split(g, a, ":"); g = a[2] } if ((g == p || index(g, p "/") == 1) && !(nt != "" && prev == "--tmpfs" && g == p)) n++; prev = $0 } END { print n + 0 }'
}
if _has "${HIDE_SRC}:/tree/pkg:ro" && [[ "$(_under /tree/pkg)" -eq 1 ]]; then
  pass "G4 a repo one level down a mounted tree is hidden: one :ro line at /tree/pkg, nothing else under it"
else
  fail "G4 nested repo /tree/pkg: hide line present: $(_has "${HIDE_SRC}:/tree/pkg:ro" && echo yes || echo no), lines at or under it: $(_under /tree/pkg)"
fi
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
# guest could create, which no mount can cover. rc creates it empty on the host
# (git reads an empty file as no config) and covers it read-only (B1 ruling,
# rip-cage-npbb round 2). Under --dry-run it writes nothing: it says "Would
# create" and the previewed argv carries the cover (round 3, B4).
REF="${T}/refrepo"
mkdir -p "$REF" && git -C "$REF" init -q && git -C "$REF" config extensions.worktreeConfig true
CONF_REF="${T}/cage-ref.yaml"
sed -e "s#^  - \"${WS}:/workspace\"#  - \"${REF}:/workspace\"#" "$CONF" > "$CONF_REF"
_dry_run "$CONF_REF" "$WS"
ARGV=$(grep '^Would run: ' <<<"$OUT" | head -1)
if [[ $RCODE -eq 0 && ! -e "${REF}/.git/config.worktree" && ! -L "${REF}/.git/config.worktree" ]] \
   && _has "${REF}/.git/config.worktree:/workspace/.git/config.worktree:ro" \
   && grep -qF "Would create ${REF}/.git/config.worktree" <<<"$OUT" \
   && ! grep -qF "created it empty" <<<"$OUT"; then
  pass "G16 --dry-run with config.worktree missing: writes nothing, says Would create, previews the ro cover"
else
  fail "G16 dry-run create preview (rc ${RCODE}, file: $(ls -l "${REF}/.git/config.worktree" 2>&1)): $(tail -3 <<<"$OUT")"
fi

# G16c: the real path (DRY_RUN unset, lib sourced) creates it empty, says so in
# one line, and covers it read-only.
_rx() {  # HOST_GITDIR -- _git_exec_ro_covers on the real (non-dry-run) path
  ( unset DRY_RUN RC_PROTECTED_SCAN_DEPTH
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/cli/lib/protected_paths.sh"; _git_exec_ro_covers "$1" /g )
}
_o=$(_rx "${REF}/.git" 2>"${T}/g16c.err"); _r=$?
if [[ $_r -eq 0 && -f "${REF}/.git/config.worktree" && ! -L "${REF}/.git/config.worktree" && ! -s "${REF}/.git/config.worktree" ]] \
   && grep -qxF -- "${REF}/.git/config.worktree:/g/config.worktree:ro" <<<"$_o" \
   && [[ $(grep -cF "created it empty" "${T}/g16c.err") -eq 1 ]]; then
  pass "G16c real launch: config.worktree created empty, one line says so, covered ro"
else
  fail "G16c real create (rc ${_r}): $(cat "${T}/g16c.err")"
fi

# G16b: rc cannot create it (the gitdir is not writable): refuse, naming the
# one touch command that fixes every missing file at once.
REF3="${T}/refrepo3"
mkdir -p "$REF3" && git -C "$REF3" init -q && git -C "$REF3" config extensions.worktreeConfig true
chmod a-w "${REF3}/.git"
CONF_REF3="${T}/cage-ref3.yaml"
sed -e "s#^  - \"${WS}:/workspace\"#  - \"${REF3}:/workspace\"#" "$CONF" > "$CONF_REF3"
_dry_run "$CONF_REF3" "$WS"
chmod u+w "${REF3}/.git"
if [[ $RCODE -ne 0 ]] && grep -qF "touch ${REF3}/.git/config.worktree" <<<"$OUT" && ! grep -q '^Would run: ' <<<"$OUT"; then
  pass "G16b config.worktree that rc cannot create refuses, naming the touch command"
else
  fail "G16b uncreatable config.worktree (rc ${RCODE}): $(tail -3 <<<"$OUT")"
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

# G18: worktree mode, worktreeConfig=true, no config.worktree anywhere: under
# --dry-run rc names both files it would create, writes neither, and previews
# both covers.
REF2="${T}/ref2"
mkdir -p "$REF2" && git -C "$REF2" init -q && _git -C "$REF2" commit -q --allow-empty -m init
_git -C "$REF2" worktree add -q "${T}/ref2-wt" -b r2
git -C "$REF2" config extensions.worktreeConfig true
CONF_WT2="${T}/cage-wt2.yaml"
sed -e "s#^  - \"${WS}:/workspace\"#  - \"${T}/ref2-wt:/workspace\"#" "$CONF" > "$CONF_WT2"
_dry_run "$CONF_WT2" "${T}/ref2-wt"
ARGV=$(grep '^Would run: ' <<<"$OUT" | head -1)
if [[ $RCODE -eq 0 && ! -e "${REF2}/.git/config.worktree" && ! -e "${REF2}/.git/worktrees/ref2-wt/config.worktree" ]] \
   && grep -qF "Would create ${REF2}/.git/config.worktree" <<<"$OUT" \
   && grep -qF "${REF2}/.git/worktrees/ref2-wt/config.worktree" <<<"$OUT" \
   && _has "${REF2}/.git/config.worktree:/workspace/.git-main/config.worktree:ro" \
   && _has "${REF2}/.git/worktrees/ref2-wt/config.worktree:/workspace/.git-main/worktrees/ref2-wt/config.worktree:ro"; then
  pass "G18 worktree mode --dry-run names both missing config.worktree files, writes neither, previews both covers"
else
  fail "G18 worktree-mode dry-run (rc ${RCODE}, written: $([[ -e "${REF2}/.git/config.worktree" ]] && echo main) $([[ -e "${REF2}/.git/worktrees/ref2-wt/config.worktree" ]] && echo linked)): $(tail -3 <<<"$OUT")"
fi

# G20: config.worktree present as anything but a regular, non-symlink file
# refuses (round 3, B3). A symlink to /dev/null passed noclobber (no O_EXCL on
# a non-regular target), printed a false "created" line and emitted no cover;
# a FIFO hung rc up. A dangling symlink is never written through (R9).
for _kind in devnull fifo dangling tofile; do
  _rp="${T}/g20-${_kind}"
  mkdir -p "$_rp" && git -C "$_rp" init -q && git -C "$_rp" config extensions.worktreeConfig true
  case "$_kind" in
    devnull)  ln -s /dev/null "${_rp}/.git/config.worktree" ;;
    fifo)     mkfifo "${_rp}/.git/config.worktree" ;;
    dangling) ln -s "${T}/g20-planted" "${_rp}/.git/config.worktree" ;;
    tofile)   : > "${T}/g20-real"; ln -s "${T}/g20-real" "${_rp}/.git/config.worktree" ;;
  esac
  # shellcheck disable=SC2016  # $1/$2 expand in the child bash, by design
  _o=$( ( unset DRY_RUN; timeout 20 bash -c 'source "$1/cli/lib/protected_paths.sh"; _git_exec_ro_covers "$2" /g' _ "$REPO_ROOT" "${_rp}/.git" ) 2>&1 ); _r=$?
  if [[ $_r -ne 0 && $_r -ne 124 ]] && grep -qF "${_rp}/.git/config.worktree" <<<"$_o" \
     && ! grep -qF -- "config.worktree:/g/config.worktree:ro" <<<"$_o" \
     && ! grep -qF "created it empty" <<<"$_o" && [[ ! -e "${T}/g20-planted" ]]; then
    pass "G20 config.worktree as ${_kind} refuses, naming it, no cover, nothing written through it"
  else
    fail "G20 config.worktree as ${_kind} (rc ${_r}; planted: $(ls "${T}/g20-planted" 2>&1)): $(tail -2 <<<"$_o")"
  fi
done

# G21: a rw mount on top of a ro one still gets its .git covers -- only a ro
# mount DEEPER than a rw one shadows it (round 3: the deepest mount owns its
# subtree). Before, any ro target above the repo dropped them (fail open).
NEST="${T}/nest"
mkdir -p "${NEST}/inner" && git -C "${NEST}/inner" init -q
printf 'mounts:\n  - "%s:/n:ro"\n  - "%s:/n/inner"\n' "$NEST" "${NEST}/inner" > "${T}/nest.yaml"
_o=$( ( unset RC_PROTECTED_SCAN_DEPTH
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/cli/lib/protected_paths.sh"; _git_exec_covers "${T}/nest.yaml" ) 2>&1 )
if grep -qxF -- "${NEST}/inner/.git/config:/n/inner/.git/config:ro" <<<"$_o"; then
  pass "G21 a rw mount nested inside a ro mount keeps its .git covers"
else
  fail "G21 rw-in-ro .git covers missing: $(tail -3 <<<"$_o")"
fi

# G19: the .git leg's own default depth (R4). A repo at depth 4 inside a rw
# mount is pinned with RC_PROTECTED_SCAN_DEPTH unset, and not at 2 -- so this
# goes red if only the .git leg's default reverts to 2. Sourced directly: the
# protected-name leg is not in play.
BENCH="${T}/bench"
mkdir -p "${BENCH}/a/b/c/repo" && git -C "${BENCH}/a/b/c/repo" init -q
printf 'mounts:\n  - "%s:/w"\n' "$BENCH" > "${T}/bench.yaml"
_gx() { ( unset RC_PROTECTED_SCAN_DEPTH; [[ $# -gt 0 ]] && export RC_PROTECTED_SCAN_DEPTH="$1"
          # shellcheck source=/dev/null
          source "${REPO_ROOT}/cli/lib/protected_paths.sh"; _git_exec_covers "${T}/bench.yaml" ) 2>&1; }
_c="${BENCH}/a/b/c/repo/.git/config:/w/a/b/c/repo/.git/config:ro"
_o=$(_gx)
if grep -qxF -- "$_c" <<<"$_o"; then pass "G19 depth unset: the .git scan covers a repo at depth 4"; else fail "G19 depth unset: depth-4 repo not covered: $(tail -3 <<<"$_o")"; fi
_o=$(_gx 2)
if ! grep -qxF -- "$_c" <<<"$_o"; then pass "G19 RC_PROTECTED_SCAN_DEPTH=2 still caps the .git scan"; else fail "G19 depth 2 did not cap the .git scan"; fi
for _d in 0 -1 abc unlimited 2.5; do
  _o=$(_gx "$_d"); _r=$?
  if [[ $_r -ne 0 ]] && grep -q 'positive integer' <<<"$_o" && ! grep -q -- '^-v$' <<<"$_o"; then
    pass "G19 RC_PROTECTED_SCAN_DEPTH=${_d} refuses the .git scan, naming the valid values"
  else
    fail "G19 RC_PROTECTED_SCAN_DEPTH=${_d} (rc ${_r}): $(tail -2 <<<"$_o")"
  fi
done

# ---------------------------------------------------------------------------
# H1-H11: the nested-repo hide (rip-cage-rsh9.17.3.1, ADR-002 D11 evolved
# 2026-11-11). Fixture: FX is a folder mounted rw at /tree holding the nested
# repo pkg (a .env, a protected-name dir .aws, a submodule pointer file, a
# nested-nested repo deep/inner, docs/), a pointer file outside it, and FXROOT
# is a mount-root repo with a .git/modules gitdir. The scan is unlimited here.
# ---------------------------------------------------------------------------
FX="${T}/fx"; FXROOT="${T}/fxroot"; FX2="${T}/fx2"; ALT="${T}/alt"
mkdir -p "${FX}/pkg/docs" "${FX}/pkg/.aws" "${FX}/pkg/subm" "${FX}/pkg/deep/inner" "${FX}/outside" "$ALT"
git -C "${FX}/pkg" init -q && git -C "${FX}/pkg/deep/inner" init -q
printf 'k=v\n' > "${FX}/pkg/.env"
printf 'secret\n' > "${FX}/pkg/.aws/credentials"
printf 'gitdir: %s/.git/modules/subm\n' "${FX}/pkg" > "${FX}/pkg/subm/.git"
printf 'gitdir: %s/.git/modules/out\n' "$FX" > "${FX}/outside/.git"
mkdir -p "$FXROOT" && git -C "$FXROOT" init -q
mkdir -p "${FXROOT}/.git/modules/sm/objects" "${FXROOT}/.git/modules/sm/hooks"
printf 'ref: refs/heads/main\n' > "${FXROOT}/.git/modules/sm/HEAD"
printf '[core]\n' > "${FXROOT}/.git/modules/sm/config"
# FX2: a repo under a tmpfs-named dir, a repo whose own dir carries such a name,
# and a repo under a file:-named dir (which gets no tmpfs).
mkdir -p "${FX2}/.aws/rep" "${FX2}/.kube" "${FX2}/credentials/rep"
for _r in "${FX2}/.aws/rep" "${FX2}/.kube" "${FX2}/credentials/rep"; do git -C "$_r" init -q; done

_mkconf() {  # <out> <mount>... -- the template plus extra mount lines after the workspace's
  local _out="$1" _ins="" _m _n; shift
  for _m in "$@"; do
    case "$_m" in
      named:*) _n="${_m#named:}"
        _ins+="\\
  - named: \"${_n%%:*}\"\\
    target: \"${_n#*:}\"" ;;
      *) _ins+="\\
  - \"${_m}\"" ;;
    esac
  done
  sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
      -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${H}#g" \
      -e "s#<CAGE-NAME>#rsh9173-test#g" \
      -e "s#^  - \"${WS}:/workspace\"#&${_ins}#" \
      "$TEMPLATE" > "$_out"
}
_run() {  # <conf name> <mount>... -- dry-run, unlimited scan; sets OUT RCODE ARGV
  local _c="${T}/h-$1.yaml"; shift
  _mkconf "$_c" "$@"
  SCAN_DEPTH="" _dry_run "$_c" "$WS"
  ARGV=$(grep '^Would run: ' <<<"$OUT" | head -1)
}
_hide_at() { _has "${HIDE_SRC}:$1:ro"; }
_git_under() {  # <guest path> -- git covers and hides at or under it (a ro mount's own protected-name covers are not the outer view's)
  tr ' ' '\n' <<<"$ARGV" | awk -v p="$1" '{ g = $0; if (index(g, ":")) { split(g, a, ":"); g = a[2] } if ((g == p || index(g, p "/") == 1) && ($0 ~ /\/\.git/ || $0 ~ /hidden-repo/)) n++ } END { print n + 0 }'
}

_run h1 "${FX}:/tree" "${FXROOT}:/fxroot"
_miss=""
[[ $RCODE -eq 0 ]] || _miss+=" exit-${RCODE}"
_hide_at /tree/pkg || _miss+=" hide-line"
[[ "$(_under /tree/pkg)" -eq 1 ]] || _miss+=" lines-under-pkg=$(_under /tree/pkg)"
_has "${FX}/outside/.git:/tree/outside/.git:ro" || _miss+=" outside-pointer-ro"
_has "${FXROOT}/.git:/fxroot/.git " || _miss+=" root-pin"
_has "${FXROOT}/.git/config:/fxroot/.git/config:ro" || _miss+=" root-config"
_has "${FXROOT}/.git/hooks:/fxroot/.git/hooks:ro" || _miss+=" root-hooks"
_has "${FXROOT}/.git/modules/sm:/fxroot/.git/modules/sm " || _miss+=" modules-pin"
_has "${FXROOT}/.git/modules/sm/config:/fxroot/.git/modules/sm/config:ro" || _miss+=" modules-config"
[[ ! -e "${H}/.cache/rc/hidden-repo" ]] || _miss+=" README-dir-created-by-dry-run"
if [[ -z "$_miss" ]]; then pass "H1 nested repo: exactly one hide line at /tree/pkg and nothing under it; root and outside-pointer covers kept; dry run creates no README dir"; else fail "H1 hide fixture --${_miss}: $(tail -3 <<<"$OUT")"; fi

_run h2 "${FX}:/tree" "${FX}/pkg:/pkgw"
_miss=""
[[ $RCODE -eq 0 ]] || _miss+=" exit-${RCODE}"
for _g in /tree/pkg /pkgw; do
  _has "${FX}/pkg/.git:${_g}/.git " || _miss+=" pin@${_g}"
  _has "${FX}/pkg/.git/config:${_g}/.git/config:ro" || _miss+=" config@${_g}"
  _has "${FX}/pkg/.git/hooks:${_g}/.git/hooks:ro" || _miss+=" hooks@${_g}"
done
_hide_at /tree/pkg && _miss+=" hide@/tree/pkg"
_hide_at /pkgw && _miss+=" hide@/pkgw"
_hide_at /tree/pkg/deep/inner || _miss+=" inner-hidden-in-outer-view"
if [[ -z "$_miss" ]]; then pass "H2 a nested repo with its own rw line is a mount root everywhere: pin and covers at both guest paths, no hide of it"; else fail "H2 own-line repo --${_miss}: $(tail -3 <<<"$OUT")"; fi

_run h3 "${FX}:/tree" "${FX}/pkg:/ref:ro"
# The read-only view shows the repo, so it keeps its protected-name cover (brain stamp review R4).
_tmpfs_at() { grep -qxF -- "$1" < <(tr ' ' '\n' <<<"$ARGV"); }
if [[ $RCODE -eq 0 ]] && _hide_at /tree/pkg && [[ "$(_under /tree/pkg)" -eq 1 && "$(_git_under /ref)" -eq 0 ]] && _tmpfs_at /ref/.aws; then
  pass "H3 a read-only own line leaves the hide at /tree/pkg, emits no git line under /ref, and keeps /ref's protected-name tmpfs"
else
  fail "H3 ro own line (rc ${RCODE}): hide $(_hide_at /tree/pkg && echo yes || echo no), under /tree/pkg $(_under /tree/pkg), under /ref $(_git_under /ref), tmpfs /ref/.aws $(_tmpfs_at /ref/.aws && echo yes || echo no)"
fi

for _v in "ro:${FX}/pkg:/tree/pkg:ro" "other:${ALT}:/tree/pkg"; do
  _run "h4${_v%%:*}" "${FX}:/tree" "${_v#*:}"
  if [[ $RCODE -eq 0 ]] && [[ "$(_git_under /tree/pkg)" -eq 0 && ( "${_v%%:*}" != other || "$(_under /tree/pkg)" -eq 0 ) ]] && ! grep -qF "${HIDE_SRC}" <<<"$ARGV"; then
    pass "H4 a mount targeted exactly on /tree/pkg (${_v%%:*}) owns it: exit 0, no rc line at or under it, no hide"
  else
    fail "H4 target-equal mount (${_v%%:*}) (rc ${RCODE}): git lines under /tree/pkg: $(_git_under /tree/pkg); $(tail -3 <<<"$OUT")"
  fi
done

_refused() {  # <fix1> <fix2> <other fix> <label> <mount>... -- non-zero, no argv, this refusal's two fixes named (and not the other refusal's)
  local _f1="$1" _f2="$2" _fo="$3" _l="$4"; shift 4
  _run "r-${_l%% *}" "${FX}:/tree" "${FXROOT}:/fxroot" "$@"
  if [[ $RCODE -ne 0 ]] && [[ -z "$ARGV" ]] && grep -qF "$_f1" <<<"$OUT" && grep -qF "$_f2" <<<"$OUT" && ! grep -qF "$_fo" <<<"$OUT"; then
    pass "H5 refused, both fixes named: ${_l}"
  else
    fail "H5 ${_l} (rc ${RCODE}): $(tail -3 <<<"$OUT")"
  fi
}
_refused_in() { _refused "its own read-write line" "drop the inner line" "mount it read-only" "$@"; }
_refused_git() { _refused "mount it read-only" "drop the line" "its own read-write line" "$@"; }
_refused_in "target strictly under the hidden repo" "${FX}/outside:/tree/pkg/o"
_refused_git "rw source is the nested repo's .git" "${FX}/pkg/.git:/g"
_refused_git "rw source is the nested repo's .git/hooks" "${FX}/pkg/.git/hooks:/gh"
_refused_git "rw .git source when pkg also has a rw own line" "${FX}/pkg:/pkgw" "${FX}/pkg/.git:/g"
_refused_git "rw .git/hooks of the mount-root repo at /h" "${FXROOT}/.git/hooks:/h"

_allowed() {  # <label> <mount>...
  local _l="$1"; shift
  _run "a-${_l%% *}" "${FX}:/tree" "${FXROOT}:/fxroot" "$@"
  if [[ $RCODE -eq 0 && -n "$ARGV" ]]; then pass "H6 allowed: ${_l}"; else fail "H6 ${_l} (rc ${RCODE}): $(tail -3 <<<"$OUT")"; fi
}
_allowed "the same .git, .git/hooks and root .git/hooks sources mounted :ro" \
  "${FX}/pkg/.git:/g:ro" "${FX}/pkg/.git/hooks:/gh:ro" "${FXROOT}/.git/hooks:/h:ro"
_allowed "a source inside the nested repo, outside its .git, targeted outside it" "${FX}/pkg/docs:/docs"

_run h7 "${FX}:/tree" "${FX2}:/t2"
_miss=""
[[ $RCODE -eq 0 ]] || _miss+=" exit-${RCODE}"
[[ "$(_under /t2/.aws/rep)" -eq 0 ]] || _miss+=" line-under-tmpfs-dir"
[[ "$(_under /t2/.kube self)" -eq 0 ]] || _miss+=" line-under-tmpfs-named-repo"
_has "${HIDE_SRC}:/t2/credentials/rep:ro" || _miss+=" file-named-dir-repo-not-hidden"
grep -qxF -- "/tree/pkg/.aws" < <(tr ' ' '\n' <<<"$ARGV") && _miss+=" tmpfs-under-hidden-repo"
grep -qxF -- "/t2/.aws" < <(tr ' ' '\n' <<<"$ARGV") || _miss+=" no-tmpfs-for-/t2/.aws(sanity)"
# The skipped repo's own directory must still get its tmpfs: skip means "the tmpfs
# hides it", so a skip with no tmpfs fails open (brain stamp review B1).
_tmpfs_at /t2/.kube || _miss+=" no-tmpfs-for-skipped-repo-own-dir-/t2/.kube"
if [[ -z "$_miss" ]]; then pass "H7 repos under or on a protected-name tmpfs get no rc line; one under a file:-named dir is hidden; no tmpfs under a hidden repo"; else fail "H7 tmpfs skip set --${_miss}: $(tail -3 <<<"$OUT")"; fi

_run h8 "${FX}:/tree" "${FX}/pkg/deep/inner:/w"
_miss=""
[[ $RCODE -eq 0 ]] || _miss+=" exit-${RCODE}"
_has "${FX}/pkg/deep/inner/.git:/w/.git " || _miss+=" pin@/w"
_has "${FX}/pkg/deep/inner/.git/config:/w/.git/config:ro" || _miss+=" config@/w"
[[ "$(_under /tree/pkg)" -eq 1 ]] || _miss+=" lines-under-pkg=$(_under /tree/pkg)"
if [[ -z "$_miss" ]]; then pass "H8 the nested-nested repo mounted rw at /w is covered only under /w; still one line under /tree/pkg"; else fail "H8 nested-nested at /w --${_miss}: $(tail -3 <<<"$OUT")"; fi

_run h9 "${FX}:/tree" "${FX}:/tree2"
if [[ $RCODE -eq 0 ]] && _hide_at /tree/pkg && _hide_at /tree2/pkg && [[ "$(_under /tree/pkg)" -eq 1 && "$(_under /tree2/pkg)" -eq 1 ]]; then
  pass "H9 a folder mounted rw at two targets gets one hide line per guest path"
else
  fail "H9 two targets (rc ${RCODE}): /tree/pkg $(_under /tree/pkg), /tree2/pkg $(_under /tree2/pkg)"
fi

# H10: the classifier seam .3c consumes -- host path and guest path per hidden entry.
_mkconf "${T}/h10.yaml" "${FX}:/tree" "${FXROOT}:/fxroot"
# shellcheck disable=SC2030,SC2031  # the subshell is the point: nothing leaks
_o=$( ( unset RC_PROTECTED_SCAN_DEPTH; export RC_PROTECTED_PATHS="${REPO_ROOT}/share/rip-cage/protected-paths"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/cli/lib/protected_paths.sh"; _git_classify_repos "${T}/h10.yaml" ) 2>&1 )
_want=$'hide\t'"${FX}/pkg"$'\t/tree/pkg'
if grep -qxF -- "$_want" <<<"$_o" && [[ "$(grep -c '^hide' <<<"$_o")" -eq 1 ]]; then
  pass "H10 _git_classify_repos prints one hide<TAB>host<TAB>guest line per hidden repo"
else
  fail "H10 classifier output: $(tr '\n' '|' <<<"$_o" | cut -c1-300)"
fi

# H11: the README dir is rc-owned: created on the real path only, only when missing.
H11HOME="${T}/h11home"; mkdir -p "$H11HOME"
_h11() {  # <DRY_RUN value> -- classify, then emit covers
  # shellcheck disable=SC2030,SC2031
  ( export HOME="$H11HOME" RC_PROTECTED_PATHS="${REPO_ROOT}/share/rip-cage/protected-paths"; unset RC_PROTECTED_SCAN_DEPTH; export DRY_RUN="$1"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/cli/lib/protected_paths.sh"
    _r="$(_protected_paths_conf_bind_mounts "${T}/h10.yaml")"
    _c="$(_git_classify_repos "${T}/h10.yaml" "$_r")" && _git_exec_covers "${T}/h10.yaml" "$_r" "$_c" ) >/dev/null 2>&1
}
_h11 true
_d="${H11HOME}/.cache/rc/hidden-repo"
[[ ! -e "$_d" ]] && _dry_ok=1 || _dry_ok=0
_h11 false
_txt_ok=0; grep -qF "clone it onto your volume" "${_d}/README.md" 2>/dev/null && grep -qF "cage-config skill" "${_d}/README.md" && _txt_ok=1
_n=$(find "$_d" -mindepth 1 | wc -l)
chmod u+w "${_d}/README.md"; printf 'kept\n' >> "${_d}/README.md"
_h11 false
if [[ $_dry_ok -eq 1 && $_txt_ok -eq 1 && $_n -eq 1 ]] && grep -qx kept "${_d}/README.md"; then
  pass "H11 README dir: absent after a dry run, one README.md with the fixed text after a real run, never rewritten"
else
  fail "H11 README dir (dry-run absent: ${_dry_ok}, text ok: ${_txt_ok}, entries: ${_n})"
fi

# H12: every config mount TARGET takes part in the deepest-mount rule and in
# refusal (a), whatever its kind (a named volume here).
W1="${T}/w1"
mkdir -p "${W1}/pkg" "${W1}/gx"; git -C "${W1}/pkg" init -q; git -C "${W1}/gx" init -q
_run h12a "${W1}:/tree" "named:vol-inside:/tree/pkg/node_modules"
if [[ $RCODE -ne 0 && -z "$ARGV" ]] && grep -qF "its own read-write line" <<<"$OUT" && grep -qF "drop the inner line" <<<"$OUT"; then
  pass "H12 a named volume targeted strictly inside a hidden repo is refused, both fixes named"
else
  fail "H12 volume inside hidden repo (rc ${RCODE}): $(tail -3 <<<"$OUT" | cut -c1-300)"
fi
_run h12b "${W1}:/tree" "named:vol-equal:/tree/gx"
if [[ $RCODE -eq 0 ]] && _hide_at /tree/pkg && [[ "$(_under /tree/gx)" -eq 0 ]]; then
  pass "H12 a named volume targeted exactly on a nested repo owns it: exit 0, no hide, no line at or under it"
else
  fail "H12 volume equal to repo path (rc ${RCODE}): under /tree/gx $(_under /tree/gx): $(tail -3 <<<"$OUT" | cut -c1-300)"
fi

# H13: content a hide makes invisible cannot make rc refuse -- a FIFO named
# .env inside a hidden repo.
W2="${T}/w2"
mkdir -p "${W2}/pkg"; git -C "${W2}/pkg" init -q; mkfifo "${W2}/pkg/.env"
_run h13 "${W2}:/tree"
if [[ $RCODE -eq 0 ]] && _hide_at /tree/pkg && [[ "$(_under /tree/pkg)" -eq 1 ]]; then
  pass "H13 a FIFO .env inside a hidden repo does not refuse the launch: exit 0, one hide line"
else
  fail "H13 fifo inside hidden repo (rc ${RCODE}): $(tail -3 <<<"$OUT" | cut -c1-300)"
fi

# H14: a protected-paths refusal keeps its own JSON code (the classifier's
# tmpfs pass must not take it over).
mkdir -p "${T}/pd/.ssh"
_mkconf "${T}/h14.yaml" "${T}/pd/.ssh:/ssh"
SCAN_DEPTH="" _dry_run "${T}/h14.yaml" "$WS" --output json
if [[ $RCODE -ne 0 ]] && grep -qF '"code":"PROTECTED_PATH_REFUSED"' <<<"$OUT"; then
  pass "H14 a direct protected-dir mount reports PROTECTED_PATH_REFUSED in json"
else
  fail "H14 json code (rc ${RCODE}): $(grep -o '"code":"[A-Z_]*"' <<<"$OUT")"
fi

# H15: a repo whose .git is a pointer FILE (--separate-git-dir) under a
# protected-name tmpfs dir gets no rc line under the tmpfs.
P2="${T}/p2"
mkdir -p "${P2}/.aws/sub"
git -C "${P2}/.aws/sub" init -q --separate-git-dir="${T}/p2-sepgit"
_run h15 "${P2}:/pp"
if [[ $RCODE -eq 0 ]] && grep -qxF -- "/pp/.aws" < <(tr ' ' '\n' <<<"$ARGV") && [[ "$(_under /pp/.aws self)" -eq 0 ]]; then
  pass "H15 a pointer-file repo under a tmpfs dir gets no rc line under the tmpfs"
else
  fail "H15 pointer file under tmpfs (rc ${RCODE}): under /pp/.aws: $(_under /pp/.aws self): $(tail -2 <<<"$OUT" | cut -c1-300)"
fi

# H16: a mount rc generates itself (a skill symlink parent) at or inside a
# hidden repo is dropped, with one printed line naming the host dir and the
# fix; the complement (the repo mounted by its own ro line) keeps the mount.
F8="${T}/f8"
mkdir -p "${F8}/home/code/dot/skills/myskill" "${F8}/home/.claude/skills"
git -C "${F8}/home/code/dot" init -q
ln -s "${F8}/home/code/dot/skills/myskill" "${F8}/home/.claude/skills/myskill"
HIDE8="${F8}/home/.cache/rc/hidden-repo"
DOT="${F8}/home/code/dot"
RUN_HOME="${F8}/home" _run h16a "${F8}/home/code:${F8}/home/code"
_miss=""
[[ $RCODE -eq 0 ]] || _miss+=" exit-${RCODE}"
_has "${HIDE8}:${DOT}:ro" || _miss+=" hide-line"
[[ "$(_under "$DOT")" -eq 1 ]] || _miss+=" lines-under-repo=$(_under "$DOT")"
grep -qF "${DOT}/skills" <<<"$(grep -v '^Would run: ' <<<"$OUT")" || _miss+=" host-dir-not-named"
grep -qF "mount ${DOT} by its own line; read-only is enough" <<<"$OUT" || _miss+=" fix-not-named"
grep -qF "Would mount ${DOT}/skills ->" <<<"$OUT" && _miss+=" preview-still-announces-the-mount"
if [[ -z "$_miss" ]]; then pass "H16 a skill symlink-parent mount inside a hidden repo is dropped and printed, exit 0"; else fail "H16 generated mount in hide --${_miss}: $(grep -v '^Would run: ' <<<"$OUT" | grep -iE 'dot|drop' | head -3 | cut -c1-300)"; fi
RUN_HOME="${F8}/home" _run h16b "${F8}/home/code:${F8}/home/code" "${DOT}:${DOT}:ro"
_miss=""
[[ $RCODE -eq 0 ]] || _miss+=" exit-${RCODE}"
grep -qF "${HIDE8}" <<<"$ARGV" && _miss+=" hide-present"
_has "${DOT}/skills:${DOT}/skills:ro" || _miss+=" skill-parent-mount-missing"
grep -qF "by its own line" <<<"$OUT" && _miss+=" printed"
if [[ -z "$_miss" ]]; then pass "H16 with the repo mounted by its own ro line: no hide, the skill-parent mount stays, nothing printed"; else fail "H16 complement --${_miss}"; fi

if grep -Eq '^(docker (save|tag|pull|build|image load)|msb (load|create|pull|image load))' "$CALL_LOG"; then
  fail "G9 dry-run reached a mutating runtime call: $(grep -E '^(docker|msb) ' "$CALL_LOG" | head -3 | tr '\n' ';')"
else
  pass "G9 call log holds no save/tag/pull/load/create"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then echo "All tests passed."; exit 0; fi
echo "${FAILURES} test(s) failed."
exit 1
