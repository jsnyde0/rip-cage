#!/usr/bin/env bash
# tests/test-mise-cache-isolation-live.sh -- container-tier proof that two
# cages built from the shipped template do not share a writable mise cache
# (rip-cage-p4ss.2, ADR-015 D2 as evolved 2026-10-16).
#
# Two scratch projects under one temp HOME and XDG_CONFIG_HOME, each with a
# config rendered from share/rip-cage/cage.yaml.template the way an operator
# fills it in:
#   M1  the two rendered configs name two different mise volumes.
#   M2  cage A boots (rc up exit 0) and plants a file in its mise data dir.
#   M3  cage B boots while A still stands.
#   M4  cage B does not see A's file -- the cross-cage channel is closed.
#   M5  `rc destroy` of each cage removes its own mise volume.
#
# No real credential is used: the config's CCTOK secret gets a fake value of
# the setup-token shape, enough for msb to boot. Nothing here calls the API.
#
# Image: RC_IMAGE, REQUIRED to be an explicit scratch tag, never
# rip-cage:latest (same guards as tests/test-init-mount-guard-live.sh). Build
# one: RC_IMAGE=<tag> rc build --file cage/Dockerfile
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
  echo "SKIP: ${IMAGE} is not current per rc's own _image_is_current check -- rc up would pull/tag/load onto it. Rebuild: RC_IMAGE=${IMAGE} rc build --file cage/Dockerfile"
  exit 0
fi

# Short, symlink-resolved scratch root (msb does not follow a host-side
# symlink in a mount source); the scratch-cage registry sweeps the names.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
T=$(_host_scratch_mktemp_d rc-live-mise)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/xdg"
export MSB_HOME="${REAL_HOME}/.microsandbox"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/skills"
echo '{}' > "$HOME/.claude.json"
[[ -e "${REAL_HOME}/.docker" ]] && ln -sfn "${REAL_HOME}/.docker" "${HOME}/.docker"
unset CCTOK

mkdir -p "${XDG_CONFIG_HOME}/rip-cage/projects" "${XDG_CONFIG_HOME}/rip-cage/secrets"
# A fake value of the setup-token shape: msb needs the env var to boot.
( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK" )

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"

# _render_project <subdir> -- make a workspace, render the shipped template
# for it at the default config path, echo the cage name.
_render_project() {
  local _ws="${T}/$1" _name
  mkdir -p "$_ws"
  git -C "$_ws" init -q
  _name=$(bash -c "source '${RC}' 2>/dev/null; container_name '$_ws'")
  [[ -n "$_name" ]] || return 1
  sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${_ws}#g" \
      -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${HOME}#g" \
      -e "s#<CAGE-NAME>#${_name}#g" \
      -e "s#^image: rip-cage:latest#image: ${IMAGE}#" \
      "${REPO_ROOT}/share/rip-cage/cage.yaml.template" \
      > "${XDG_CONFIG_HOME}/rip-cage/projects/${_name}.yaml"
  printf '%s\n' "$_name"
}

_mise_vol() {
  sed -n 's#^ *- named: "\(.*\)"$#\1#p' "${XDG_CONFIG_HOME}/rip-cage/projects/$1.yaml" | grep '^rc-mise-cache'
}

gexec() {
  local _cage="$1" _secs="$2"; shift 2
  perl -e 'alarm shift; exec @ARGV' "$_secs" msb exec "$_cage" -- "$@" < /dev/null
}

A=$(_render_project proj-a) || { echo "FATAL: could not derive cage name A"; exit 1; }
B=$(_render_project proj-b) || { echo "FATAL: could not derive cage name B"; exit 1; }
scratch_cage_register "$A"
scratch_cage_register "$B"
echo "cageA=${A} cageB=${B} image=${IMAGE}"

VOL_A=$(_mise_vol "$A"); VOL_B=$(_mise_vol "$B")
if [[ -n "$VOL_A" && -n "$VOL_B" && "$VOL_A" != "$VOL_B" ]]; then
  pass "M1 rendered configs name two mise volumes: ${VOL_A} / ${VOL_B}"
else
  fail "M1 rendered configs do not name two distinct mise volumes" "A='${VOL_A}' B='${VOL_B}'"
fi

if "$RC" up "${T}/proj-a" < /dev/null > "${T}/up-a.log" 2>&1 \
    && gexec "$A" 30 bash -c 'touch ~/.local/share/mise/PLANT-p4ss2 && test -e ~/.local/share/mise/PLANT-p4ss2'; then
  pass "M2 cage A up; PLANT written to its mise data dir"
else
  fail "M2 cage A up + plant" "log tail: $(tail -5 "${T}/up-a.log" | tr '\n' ' ')"
fi

if "$RC" up "${T}/proj-b" < /dev/null > "${T}/up-b.log" 2>&1; then
  pass "M3 cage B up while A stands"
  seen=$(gexec "$B" 30 bash -c 'test -e ~/.local/share/mise/PLANT-p4ss2 && echo seen || echo absent' 2>/dev/null | tr -d '\r\n')
  if [[ "$seen" == "absent" ]]; then
    pass "M4 cage B does not see cage A's PLANT"
  else
    fail "M4 cage B sees cage A's mise cache" "probe='${seen}'"
  fi
else
  fail "M3 cage B up" "log tail: $(tail -5 "${T}/up-b.log" | tr '\n' ' ')"
fi

for _pair in "${A}:${VOL_A}" "${B}:${VOL_B}"; do
  _c="${_pair%%:*}"; _v="${_pair#*:}"
  if "$RC" destroy "$_c" < /dev/null > /dev/null 2>&1; then
    # Gone: hand it back from the scratch registry so the exit trap does not
    # destroy it a second time and report a leak.
    _keep=()
    for _n in "${_SCRATCH_CAGE_NAMES[@]}"; do [[ "$_n" == "$_c" ]] || _keep+=("$_n"); done
    _SCRATCH_CAGE_NAMES=("${_keep[@]+"${_keep[@]}"}")
    _scratch_cage_registry_remove "$_c"
  fi
  if [[ -n "$_v" ]] && ! msb volume inspect "$_v" >/dev/null 2>&1; then
    pass "M5 rc destroy ${_c} removed ${_v}"
  else
    fail "M5 rc destroy ${_c} left its mise volume" "vol='${_v}'"
  fi
done

echo ""
if [[ $FAILS -eq 0 ]]; then echo "ALL LIVE CHECKS PASSED"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"
exit 1
