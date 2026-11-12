#!/usr/bin/env bash
# tests/test-git-config-cover-live.sh -- container-tier proof for
# rip-cage-rsh9.2 (ADR-002 D11 evolved 2026-10-16): inside a real cage, the
# guest cannot write a git config key the host's git would run, for the
# workspace repo AND a second repo the config mounts; and the everyday git
# loop still works within the accepted costs.
#
# One scratch cage from the shipped template, plus two extra mounts: a second
# repo at /other and a bare remote at /remote.
#   C1  rc up exits 0
#   C2  `git config core.fsmonitor` fails in /workspace; host config unchanged
#   C3  the same in the second mounted repo /other
#   C4  `mv /workspace/.git` fails (the pin); host .git still in place
#   C5  commit works; `git push -u origin feat` lands the branch on the remote
#       (exit 0; no upstream is recorded -- the accepted cost)
#   C6  a second commit, then a bare `git push`, lands too (image
#       push.default=current)
#   C7  the in-cage safety-stack D11 checks pass
#   C9  rip-cage-rsh9.17.3.1 (the nested-repo hide, ADR-002 D11): a repo nested in a
#       rw-mounted folder (/tree/pkg) lists only README.md in the cage
#   C10 as the agent user, writing under it and `umount` fail
#   C11 the user-namespace leg: `unshare -Urm` makes a namespace, `umount`
#       is what fails, README.md is still the only entry -- or SKIP with the
#       reason when user namespaces are disabled (never a vacuous PASS)
#   C12 the floor probe passes in the hide cage
#   C13 rip-cage-rsh9.17.3.3: rc up on create printed one line per (hidden repo, guest path)
#   C14 after `msb stop`, a second repo added to the folder and rc up: rc says the hidden
#       repos changed, recreates, and /tree/pkg2 lists only README.md
#   C15 with the cage running and a third repo added: rc up attaches, reports the two
#       created-with guest paths and says rc up --replace applies the change
#   C8  `git config --worktree core.fsmonitor` fails in /other, which uses
#       extensions.worktreeConfig; host config.worktree unchanged
#
# No real credential is used (fake CCTOK of the setup-token shape).
#
# Image: RC_IMAGE, REQUIRED to be an explicit scratch tag, never
# rip-cage:latest. Build one: RC_IMAGE=<tag> rc build --file cage/Dockerfile
#
# NEEDS_CONTAINER.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"
REAL_HOME="$HOME"

FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ -- $2}"; FAILS=$((FAILS + 1)); }

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
if [[ -z "${RC_IMAGE:-}" ]]; then
  echo "SKIP: RC_IMAGE must be set to an explicit scratch tag other than rip-cage:latest. Build one: RC_IMAGE=<tag> rc build --file cage/Dockerfile"
  exit 0
fi
# rip-cage-b8kd.44: every spelling of the production tag, not just the literal.
if scratch_image_is_production "$RC_IMAGE"; then
  echo "FAIL: RC_IMAGE=${RC_IMAGE} names the operator's production tag (rip-cage:latest) -- this test never boots a cage on it. Build a scratch tag: RC_IMAGE=<tag> rc build --file cage/Dockerfile"
  exit 1
fi
IMAGE="$RC_IMAGE"
command -v msb >/dev/null 2>&1 || { echo "SKIP: msb not on PATH"; exit 0; }
msb image inspect "$IMAGE" --format json >/dev/null 2>&1 || { echo "SKIP: image ${IMAGE} not in msb's cache"; exit 0; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "SKIP: image ${IMAGE} not in docker's store (refusing to let rc up pull)"; exit 0; }
if ! ( RC_IMAGE="$IMAGE" bash -c "source '${RC}' 2>/dev/null; _image_is_current" ); then
  echo "SKIP: ${IMAGE} is not current per rc's own _image_is_current check. Rebuild: RC_IMAGE=${IMAGE} rc build --file cage/Dockerfile"
  exit 0
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
T=$(_host_scratch_mktemp_d rc-live-gitcov)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/xdg"
export MSB_HOME="${REAL_HOME}/.microsandbox"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/skills"
echo '{}' > "$HOME/.claude.json"
[[ -e "${REAL_HOME}/.docker" ]] && ln -sfn "${REAL_HOME}/.docker" "${HOME}/.docker"
unset CCTOK

WS="${T}/ws"; OTHER="${T}/other"; REMOTE="${T}/remote.git"
for _r in "$WS" "$OTHER"; do
  mkdir -p "$_r"
  git -C "$_r" init -q -b main
  git -C "$_r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
done
git init -q --bare "$REMOTE"
git -C "$WS" remote add origin /remote
# /other uses per-worktree config, as `git sparse-checkout` sets it up: git
# reads .git/config.worktree too, a second config source (C8).
git -C "$OTHER" config extensions.worktreeConfig true
git -C "$OTHER" config --worktree rc.test host
WS_CFG_BEFORE=$(cksum < "${WS}/.git/config")
OTHER_CFG_BEFORE=$(cksum < "${OTHER}/.git/config")
OTHER_WTCFG_BEFORE=$(cksum < "${OTHER}/.git/config.worktree")
# A nested repo below a rw-mounted folder: the hide target (C9-C12).
TREE="${T}/tree"
mkdir -p "${TREE}/pkg"
git -C "${TREE}/pkg" init -q -b main
printf 'host secret\n' > "${TREE}/pkg/secret.txt"

NAME=$(bash -c "source '${RC}' 2>/dev/null; container_name '$WS'")
[[ -n "$NAME" ]] || { echo "FATAL: could not derive cage name"; exit 1; }
mkdir -p "${XDG_CONFIG_HOME}/rip-cage/projects" "${XDG_CONFIG_HOME}/rip-cage/secrets"
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${HOME}#g" \
    -e "s#<CAGE-NAME>#${NAME}#g" \
    -e "s#^image: rip-cage:latest#image: ${IMAGE}#" \
    -e "s#^  - \"${WS}:/workspace\"#&\\
  - \"${OTHER}:/other\"\\
  - \"${TREE}:/tree\"\\
  - \"${REMOTE}:/remote\"#" \
    "${REPO_ROOT}/share/rip-cage/cage.yaml.template" \
    > "${XDG_CONFIG_HOME}/rip-cage/projects/${NAME}.yaml"
( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK" )

scratch_cage_register "$NAME"
echo "cage=${NAME} image=${IMAGE}"

g() {  # g <secs> <shell snippet> -- run as the agent in the guest
  perl -e 'alarm shift; exec @ARGV' "$1" msb exec "$NAME" -- bash -lc "$2" < /dev/null
}

if "$RC" up "$WS" < /dev/null > "${T}/up.log" 2>&1; then
  pass "C1 rc up exit 0"
else
  fail "C1 rc up" "log tail: $(tail -5 "${T}/up.log" | tr '\n' ' ')"
  echo "${FAILS} LIVE CHECK(S) FAILED"; exit 1
fi

for _pair in "C2:/workspace:${WS}:${WS_CFG_BEFORE}" "C3:/other:${OTHER}:${OTHER_CFG_BEFORE}"; do
  IFS=: read -r _id _gdir _hdir _before <<<"$_pair"
  out=$(g 30 "git -C ${_gdir} config core.fsmonitor 'touch /tmp/rsh92' 2>&1; echo rc=\$?")
  after=$(cksum < "${_hdir}/.git/config")
  if [[ "$out" != *"rc=0"* && "$after" == "$_before" ]]; then
    pass "${_id} ${_gdir}: core.fsmonitor write refused, host config unchanged ($(head -1 <<<"$out"))"
  else
    fail "${_id} ${_gdir}: core.fsmonitor write" "out='${out}' host config changed: $([[ "$after" == "$_before" ]] && echo no || echo yes)"
  fi
done

out=$(g 30 "git -C /other config --worktree core.fsmonitor 'touch /tmp/rsh92' 2>&1; echo rc=\$?")
after=$(cksum < "${OTHER}/.git/config.worktree")
if [[ "$out" != *"rc=0"* && "$after" == "$OTHER_WTCFG_BEFORE" ]] \
    && ! git -C "$OTHER" config --get core.fsmonitor >/dev/null; then
  pass "C8 /other: git config --worktree core.fsmonitor refused, host config.worktree unchanged ($(head -1 <<<"$out"))"
else
  fail "C8 /other: config.worktree write" "out='${out}' host config.worktree changed: $([[ "$after" == "$OTHER_WTCFG_BEFORE" ]] && echo no || echo yes)"
fi

out=$(g 30 "mv /workspace/.git /workspace/.git-moved 2>&1; echo rc=\$?")
if [[ "$out" != *"rc=0"* && -d "${WS}/.git" && ! -e "${WS}/.git-moved" ]]; then
  pass "C4 mv /workspace/.git refused ($(head -1 <<<"$out"))"
else
  fail "C4 mv /workspace/.git" "out='${out}'"
fi

out=$(g 60 "cd /workspace && git switch -q -c feat && git commit -q --allow-empty -m one && git push -q -u origin feat 2>&1; echo rc=\$?")
if [[ "$out" == *"rc=0"* ]] && git -C "$REMOTE" rev-parse -q --verify refs/heads/feat >/dev/null; then
  pass "C5 commit + git push -u origin feat lands the branch (exit 0)"
else
  fail "C5 push -u" "out='${out}'"
fi
first=$(git -C "$REMOTE" rev-parse refs/heads/feat 2>/dev/null)

out=$(g 60 "cd /workspace && git commit -q --allow-empty -m two && git push -q 2>&1; echo rc=\$?")
second=$(git -C "$REMOTE" rev-parse refs/heads/feat 2>/dev/null)
if [[ "$out" == *"rc=0"* && -n "$second" && "$second" != "$first" ]]; then
  pass "C6 bare git push lands the next commit (push.default=current)"
else
  fail "C6 bare git push" "out='${out}' remote feat ${first} -> ${second}"
fi

out=$(g 120 "bash /usr/local/lib/rip-cage/test-safety-stack.sh 2>&1 | grep -E 'D11|\\.git cannot be renamed'")
if grep -q 'read-only: core.fsmonitor and core.hooksPath writes refused' <<<"$out" \
    && ! grep -qiE '^ *(\[?FAIL|✗)' <<<"$out" && ! grep -q 'KNOWN' <<<"$out"; then
  pass "C7 in-cage safety-stack D11 checks pass"
else
  fail "C7 in-cage safety-stack D11 checks" "$(tr '\n' ' ' <<<"$out")"
fi

# C9-C12: the nested-repo hide holds (rip-cage-rsh9.17.3.1).
out=$(g 30 "ls -A /tree/pkg")
if [[ "$out" == "README.md" ]]; then
  pass "C9 ls -A /tree/pkg prints only README.md"
else
  fail "C9 ls -A /tree/pkg" "out='$(tr '\n' ' ' <<<"$out")'"
fi

out=$(g 30 "touch /tree/pkg/planted 2>&1; echo touch=\$?; umount /tree/pkg 2>&1; echo umount=\$?; ls -A /tree/pkg")
if grep -q 'touch=[1-9]' <<<"$out" && grep -q 'umount=[1-9]' <<<"$out" && [[ ! -e "${TREE}/pkg/planted" ]] \
    && [[ "$(tail -1 <<<"$out")" == "README.md" ]]; then
  pass "C10 as the agent user, writing under /tree/pkg and umount both fail; README.md still the only entry"
else
  fail "C10 write/umount under the hide" "out='$(tr '\n' ' ' <<<"$out")' host planted: $([[ -e "${TREE}/pkg/planted" ]] && echo yes || echo no)"
fi

if [[ "$(g 30 "unshare -Urm true >/dev/null 2>&1; echo \$?")" != "0" ]]; then
  echo "SKIP C11 unshare -Urm: could not create a user namespace in this cage ($(g 30 "unshare -Urm true 2>&1 | head -1" | tr '\n' ' '))"
else
  out=$(g 30 "unshare -Urm bash -c 'echo ns-created; umount /tree/pkg 2>&1; echo umount=\$?; ls -A /tree/pkg'")
  if grep -qx 'ns-created' <<<"$out" && grep -q 'umount=[1-9]' <<<"$out" && [[ "$(tail -1 <<<"$out")" == "README.md" ]]; then
    pass "C11 unshare -Urm: namespace created, umount of /tree/pkg failed, README.md still the only entry"
  else
    fail "C11 unshare -Urm leg" "out='$(tr '\n' ' ' <<<"$out")'"
  fi
fi

out=$(g 120 "/usr/local/lib/rip-cage/floor-probe.sh > /tmp/fp.out 2>&1; echo floor-rc=\$?; tail -2 /tmp/fp.out")
if grep -qx 'floor-rc=0' <<<"$out"; then
  pass "C12 the floor probe passes ($(tail -1 <<<"$out"))"
else
  fail "C12 floor probe" "out='$(tr '\n' ' ' <<<"$out")'"
fi

# C13-C15: the hidden set round-trips through msb (rip-cage-rsh9.17.3.3). The
# cage was created hiding one repo, /tree/pkg.
if [[ "$(grep -c '^Hiding git repo' "${T}/up.log")" -eq 1 ]] \
    && grep -qF "Hiding git repo ${TREE}/pkg at /tree/pkg: clone it onto your volume (cage-config skill)" "${T}/up.log"; then
  pass "C13 rc up on create printed one line per (hidden repo, guest path): $(grep '^Hiding git repo' "${T}/up.log")"
else
  fail "C13 create print" "up.log: $(grep -i 'hid' "${T}/up.log" | tr '\n' '|')"
fi

# C14: stop the cage, add a second repo to the host folder, rc up: the label
# differs, so rc recreates and the new repo is hidden too.
mkdir -p "${TREE}/pkg2"
git -C "${TREE}/pkg2" init -q -b main
printf 'host secret two\n' > "${TREE}/pkg2/secret.txt"
msb stop "$NAME" > "${T}/stop.log" 2>&1 < /dev/null || true
if perl -e 'alarm shift; exec @ARGV' 600 "$RC" up "$WS" < /dev/null > "${T}/up2.log" 2>&1; then _up2=0; else _up2=$?; fi
out=$(g 30 "ls -A /tree/pkg2")
if [[ "$_up2" -eq 0 && "$out" == "README.md" ]] && grep -qE '^Hidden repos changed since cage' "${T}/up2.log" \
    && [[ "$(grep -c '^Hiding git repo' "${T}/up2.log")" -eq 2 ]]; then
  pass "C14 after msb stop and a second repo: rc up recreated (\"$(grep -E '^Hidden repos changed' "${T}/up2.log" | cut -c1-70)...\") and /tree/pkg2 lists only README.md"
else
  fail "C14 recreate on a changed hidden set" "exit=${_up2} ls='$(tr '\n' ' ' <<<"$out")' up2.log: $(grep -iE 'hid|error' "${T}/up2.log" | tr '\n' '|' | cut -c1-400)"
fi

# C15: the cage is running; a third repo appears. rc up attaches (no
# recreate), reports the two created-with guest paths (no host path, no third)
# and says rc up --replace applies the change.
mkdir -p "${TREE}/pkg3"
git -C "${TREE}/pkg3" init -q -b main
if perl -e 'alarm shift; exec @ARGV' 300 "$RC" up "$WS" < /dev/null > "${T}/up3.log" 2>&1; then _up3=0; else _up3=$?; fi
_rep=$(grep 'as created with' "${T}/up3.log" | head -1)
if [[ "$_up3" -eq 0 && "$_rep" == *"/tree/pkg"* && "$_rep" == *"/tree/pkg2"* && "$_rep" != *"pkg3"* && "$_rep" != *"${TREE}"* ]] \
    && grep -qF 'rc up --replace applies the change' "${T}/up3.log" \
    && ! grep -qE 'Converging|Recreating|Creating container' "${T}/up3.log"; then
  pass "C15 attach to the running cage: reports the two created-with guest paths and says rc up --replace applies the change: ${_rep}"
else
  fail "C15 attach report" "exit=${_up3} report='${_rep}' up3.log: $(tr '\n' '|' < "${T}/up3.log" | cut -c1-500)"
fi

echo ""
if [[ $FAILS -eq 0 ]]; then echo "ALL LIVE CHECKS PASSED"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"
exit 1
