#!/usr/bin/env bash
set -uo pipefail

# tests/test-protected-paths-authority-dirs.sh -- host-tier proof for
# rip-cage-jdl2.1 (ADR-032 D2): _mount_src_overlaps_authority_dir is true when
# a mount source equals, contains, or lies inside the default projects dir
# (always), the --conf config's directory, or the state directory root --
# whether or not those exist -- and false otherwise.
#
# Sources cli/lib/protected_paths.sh only; scratch HOME/XDG; no docker, no msb.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

T=$(mktemp -d /tmp/rc-authdirs-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

# Hermetic guard: names, sizes and mtimes (never contents) of the operator's
# real rip-cage dirs must be identical after the run.
REAL_HOME="${HOME:-}"
_real_sig() { find "${REAL_HOME}/.config/rip-cage" "${REAL_HOME}/.local/state/rip-cage" -ls 2>&1 | sort | cksum; }
_real_before="$(_real_sig)"

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
unset RC_STATE_DIR
mkdir -p "$HOME"
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"

PROJ="${XDG_CONFIG_HOME}/rip-cage/projects"
STATE="${XDG_STATE_HOME}/rip-cage"
mkdir -p "$PROJ" "${T}/home/unrelated" "${T}/home/.config/rip-cage/projects-other" \
  "${T}/elsewhere/sub" "${T}/custom-state/c1"
printf 'x\n' > "${PROJ}/demo.tools.yaml"
printf 'x\n' > "${T}/home/unrelated/file.txt"
printf 'x\n' > "${T}/elsewhere/proj.yaml"

yes_() { # LABEL SRC CONF_DIR
  if _mount_src_overlaps_authority_dir "$2" "$3"; then pass "$1"; else fail "$1 (expected overlap, got none)"; fi
}
no_() {
  if _mount_src_overlaps_authority_dir "$2" "$3"; then fail "$1 (expected no overlap, got one)"; else pass "$1"; fi
}

echo "--- projects dir (always) ---"
yes_ "projects dir itself" "$PROJ" ""
yes_ "parent ~/.config" "${T}/home/.config" ""
yes_ "child inside projects dir" "$PROJ/sub" ""
yes_ "file inside projects dir" "$PROJ/demo.tools.yaml" ""
yes_ "trailing slash spelling" "$PROJ/" ""
yes_ "\$HOME contains it" "$HOME" ""

echo "--- --conf directory ---"
yes_ "conf dir itself" "${T}/elsewhere" "${T}/elsewhere"
yes_ "conf dir parent" "${T}" "${T}/elsewhere"
yes_ "conf dir child" "${T}/elsewhere/sub" "${T}/elsewhere"
yes_ "conf file in conf dir" "${T}/elsewhere/proj.yaml" "${T}/elsewhere"
yes_ "default projects dir still refused when conf is elsewhere" "$PROJ" "${T}/elsewhere"
no_  "conf dir unset: elsewhere is not an authority dir" "${T}/elsewhere" ""

echo "--- state root, default (nonexistent) ---"
if [[ ! -e "$STATE" ]]; then pass "state root does not exist (precondition)"; else fail "state root exists"; fi
yes_ "state root itself, nonexistent" "$STATE" ""
yes_ "parent ~/.local/state, nonexistent root" "$XDG_STATE_HOME" ""
yes_ "child of nonexistent state root" "$STATE/cage1/calls" ""
mkdir -p "$STATE/cage1"
yes_ "state root itself, existing" "$STATE" ""
yes_ "child of existing state root" "$STATE/cage1" ""
yes_ "parent ~/.local/state, existing root" "$XDG_STATE_HOME" ""

echo "--- RC_STATE_DIR honoured ---"
export RC_STATE_DIR="${T}/custom-state"
yes_ "custom state root itself" "${T}/custom-state" ""
yes_ "custom state root parent" "${T}" ""
yes_ "custom state root child" "${T}/custom-state/c1" ""
no_  "default state root is not checked when RC_STATE_DIR is set" "$STATE/cage1" ""
export RC_STATE_DIR="${T}/not-yet/state"
yes_ "nonexistent custom root itself" "${T}/not-yet/state" ""
yes_ "nonexistent custom root's existing ancestor" "${T}" ""
yes_ "child of nonexistent custom root" "${T}/not-yet/state/x" ""
unset RC_STATE_DIR

echo "--- symlinked source ---"
ln -s "$PROJ" "${T}/link-to-projects"
yes_ "symlink to projects dir" "${T}/link-to-projects" ""
ln -s "${T}/gone" "${T}/dangling"
yes_ "dangling symlink source fails closed" "${T}/dangling" ""

echo "--- false cases ---"
no_ "unrelated dir" "${T}/home/unrelated" ""
no_ "unrelated file" "${T}/home/unrelated/file.txt" ""
no_ "sibling with common prefix (projects-other)" "${T}/home/.config/rip-cage/projects-other" ""
no_ "sibling state-like prefix" "${T}/home/.local/state-other" ""
no_ "empty source" "" ""
no_ "empty source with conf dir" "" "${T}/elsewhere"

echo "--- dangling authority dir is compared by its best lexical resolution ---"
mkdir -p "${T}/ws2" "${T}/home/.local"
rm -rf "${T}/home/.local/state"
ln -s "${T}/ws2/not-yet" "${T}/home/.local/state"
yes_ "dangling ~/.local/state -> <ws>/not-yet: <ws> overlaps" "${T}/ws2" ""
yes_ "dangling state link: the target dir itself" "${T}/ws2/not-yet" ""
no_  "dangling state link: unrelated sibling of <ws>" "${T}/home/unrelated" ""
yes_ "dangling state link: the link's own parent (~/.local) overlaps" "${T}/home/.local" ""
yes_ "dangling state link: the link's parent's parent (~) overlaps" "${T}/home" ""
rm -f "${T}/home/.local/state"

echo "--- relative RC_STATE_DIR is resolved against \$PWD ---"
mkdir -p "${T}/rel-base"
if (
  cd "${T}/rel-base" || exit 1
  export RC_STATE_DIR="rel-state"
  _mount_src_overlaps_authority_dir "${T}/rel-base/rel-state" "" || exit 1
  _mount_src_overlaps_authority_dir "${T}/rel-base/rel-state/c1" "" || exit 1
  _mount_src_overlaps_authority_dir "${T}/rel-base" "" || exit 1
  [[ "$(_protected_paths_authority_dirs "" | tail -n 1)" == "${T}/rel-base/rel-state" ]] || exit 1
  ! _mount_src_overlaps_authority_dir "${T}/rel-base-other" ""
); then pass "relative RC_STATE_DIR matches its absolute form"; else fail "relative RC_STATE_DIR"; fi

echo "--- authority list ---"
_list="$(_protected_paths_authority_dirs "${T}/elsewhere")"
if [[ "$_list" == "${PROJ}
${T}/elsewhere
${STATE}" ]]; then pass "list names projects, conf dir, state root in order"; else fail "authority list: $_list"; fi
_list="$(_protected_paths_authority_dirs "$PROJ")"
if [[ "$_list" == "${PROJ}
${STATE}" ]]; then pass "conf dir equal to projects dir is not repeated"; else fail "authority list (dup): $_list"; fi

echo "--- hermeticity ---"
if [[ "$(_real_sig)" == "$_real_before" ]]; then pass "real HOME rip-cage dirs unchanged (names, sizes, mtimes)"; else fail "real HOME rip-cage dirs changed"; fi

echo ""
echo "failures: $FAILURES"
exit $((FAILURES > 0))
