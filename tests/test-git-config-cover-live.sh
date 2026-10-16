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

if [[ -z "${RC_IMAGE:-}" || "$RC_IMAGE" == "rip-cage:latest" ]]; then
  echo "SKIP: RC_IMAGE must be set to an explicit scratch tag other than rip-cage:latest. Build one: RC_IMAGE=<tag> rc build --file cage/Dockerfile"
  exit 0
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

NAME=$(bash -c "source '${RC}' 2>/dev/null; container_name '$WS'")
[[ -n "$NAME" ]] || { echo "FATAL: could not derive cage name"; exit 1; }
mkdir -p "${XDG_CONFIG_HOME}/rip-cage/projects" "${XDG_CONFIG_HOME}/rip-cage/secrets"
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${HOME}#g" \
    -e "s#<CAGE-NAME>#${NAME}#g" \
    -e "s#^image: rip-cage:latest#image: ${IMAGE}#" \
    -e "s#^  - \"${WS}:/workspace\"#&\\
  - \"${OTHER}:/other\"\\
  - \"${REMOTE}:/remote\"#" \
    "${REPO_ROOT}/share/rip-cage/cage.yaml.template" \
    > "${XDG_CONFIG_HOME}/rip-cage/projects/${NAME}.yaml"
( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK" )

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
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

echo ""
if [[ $FAILS -eq 0 ]]; then echo "ALL LIVE CHECKS PASSED"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"
exit 1
