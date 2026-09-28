#!/usr/bin/env bash
# tests/test-init-mount-guard-live.sh -- container-tier proof that init never
# deletes, overwrites, or links into a host path that sits inside a
# cage-config mount (rip-cage-f08b, rip-cage-5fny).
#
# One scratch cage under a temp HOME and XDG_CONFIG_HOME, two boots:
#   G1-G2  shipped template: init exits 0 and ~/.claude/skills is rc's
#          projection symlink, as before.
#   G3-G6  the template with its projects/sessions lines swapped for ONE
#          read-write mount of the whole temp HOME/.claude, a sentinel file
#          under HOME/.claude/skills: rc up (init included) exits 0, init
#          prints the skip line naming the mount, the sentinel still exists
#          on the host, and HOST ~/.claude/skills is still a real directory.
#   G2b    template boot: rc's settings.json still installs (the 5fny guard
#          does not fire on a normal cage).
#   G7-G11 same whole-~/.claude boot (rip-cage-5fny): host sentinel
#          settings.json and CLAUDE.md are byte-identical after init, no
#          .claude.json.seed lands on the host, host projects/ and sessions/
#          gain no legacy-volume link, and init printed a skip line for each
#          of the five.
#
# No real credential is used: the config's CCTOK secret gets a fake value of
# the setup-token shape, enough for msb to boot. Nothing here calls the API.
#
# Image: RC_IMAGE, REQUIRED to be an explicit scratch tag, never
# rip-cage:latest (same guards as tests/test-auth-secret-live.sh). Build one:
# RC_IMAGE=<tag> rc build --file cage/Dockerfile
#
# NEEDS_CONTAINER (registered in tests/run-host.sh).
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

# macOS: msb does not follow a host-side symlink in a mount source; /tmp is one.
_tmp_root=/tmp
[[ -d /private/tmp ]] && _tmp_root=/private/tmp
T=$(mktemp -d "${_tmp_root}/rc-live-mguard.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/xdg"
export MSB_HOME="${REAL_HOME}/.microsandbox"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/skills"
echo '{}' > "$HOME/.claude.json"
[[ -e "${REAL_HOME}/.docker" ]] && ln -sfn "${REAL_HOME}/.docker" "${HOME}/.docker"
unset CCTOK

WS="${T}/ws"
mkdir -p "$WS"
git -C "$WS" init -q
echo "# init mount guard proof" > "$WS/README"
export RC_ALLOWED_ROOTS="$T"

NAME=$(bash -c "source '${RC}' 2>/dev/null; container_name '$WS'")
[[ -n "$NAME" ]] || { echo "FATAL: could not derive cage name"; exit 1; }

mkdir -p "${XDG_CONFIG_HOME}/rip-cage/projects" "${XDG_CONFIG_HOME}/rip-cage/secrets"
CONF="${XDG_CONFIG_HOME}/rip-cage/projects/${NAME}.yaml"
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${HOME}#g" \
    -e "s#<CAGE-NAME>#${NAME}#g" \
    -e "s#^image: rip-cage:latest#image: ${IMAGE}#" \
    "${REPO_ROOT}/share/rip-cage/cage.yaml.template" > "$CONF"
# A fake value of the setup-token shape: msb needs the env var to boot; no
# call in this test reaches the API.
( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK" )

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
scratch_cage_register "$NAME"
echo "cage=${NAME} image=${IMAGE}"

gexec() {
  local _secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$_secs" msb exec "$NAME" -- "$@" < /dev/null
}

# --- G1-G2: template config ----------------------------------------------
UP_LOG="${T}/up-template.log"
"$RC" up "$WS" < /dev/null > "$UP_LOG" 2>&1
up_rc=$?
if [[ $up_rc -eq 0 ]]; then pass "G1 template config: rc up (init included) exit 0"; else fail "G1 template rc up exit ${up_rc}" "log tail: $(tail -5 "$UP_LOG" | tr '\n' ' ')"; exit 1; fi
skills_link=$(gexec 30 readlink /home/agent/.claude/skills 2>/dev/null)
if [[ "$skills_link" == "/home/agent/.rc-context/skills" ]]; then pass "G2 ~/.claude/skills -> ${skills_link}"; else fail "G2 ~/.claude/skills is not the rc projection symlink" "readlink=${skills_link:-<none>}"; fi
# rip-cage-5fny: the guard must not fire on a normal cage -- rc's settings
# still install when nothing mounts ~/.claude itself.
mode=$(gexec 30 jq -r '.permissions.defaultMode // empty' /home/agent/.claude/settings.json 2>/dev/null)
if [[ "$mode" == "bypassPermissions" ]]; then pass "G2b template cage: rc's settings.json installed (defaultMode=${mode})"; else fail "G2b template cage: rc's settings.json not installed" "defaultMode=${mode:-<none>}"; fi

# --- G3-G6: whole ~/.claude mounted read-write ---------------------------
SENTINEL="${HOME}/.claude/skills/SENTINEL-f08b"
echo "must survive init" > "$SENTINEL"
# rip-cage-5fny: the host's own settings.json and CLAUDE.md sit inside the
# same mount; init must leave both byte-identical and create no seed there.
printf '{"host-sentinel": "5fny"}\n' > "${HOME}/.claude/settings.json"
printf '# host CLAUDE.md sentinel (5fny)\n' > "${HOME}/.claude/CLAUDE.md"
cp "${HOME}/.claude/settings.json" "${T}/settings.json.orig"
cp "${HOME}/.claude/CLAUDE.md" "${T}/CLAUDE.md.orig"
rm -f "${HOME}/.claude/.claude.json.seed"
ls -A "${HOME}/.claude/projects" > "${T}/projects.ls.orig"
ls -A "${HOME}/.claude/sessions" > "${T}/sessions.ls.orig"
WHOLE_CONF="${T}/whole-claude.yaml"
sed -e '\#/.claude/projects:/home/agent/.claude/projects"#d' \
    -e '\#/.claude/sessions:/home/agent/.claude/sessions"#d' \
    -e "s#^  - \"${WS}:/workspace\"#&\\
  - \"${HOME}/.claude:/home/agent/.claude\"#" \
    "$CONF" > "$WHOLE_CONF"
if ! grep -qF "\"${HOME}/.claude:/home/agent/.claude\"" "$WHOLE_CONF"; then
  fail "G3 could not build the whole-~/.claude config fixture"
else
  cp "$WHOLE_CONF" "$CONF"
  W_LOG="${T}/up-whole.log"
  "$RC" up --replace "$WS" < /dev/null > "$W_LOG" 2>&1
  w_rc=$?
  if [[ $w_rc -eq 0 ]]; then pass "G3 whole-~/.claude rw config: rc up (init included) exit 0"; else fail "G3 whole-~/.claude rc up exit ${w_rc}" "log tail: $(tail -5 "$W_LOG" | tr '\n' ' ')"; fi
  # shellcheck disable=SC2088  # literal text init prints, not a path
  if grep -qF "~/.claude/skills sits inside the cage-config mount /home/agent/.claude;" "$W_LOG"; then
    pass "G4 init printed the skip line naming /home/agent/.claude"
  else
    fail "G4 skip line absent from rc up output" "skills lines: $(grep -i 'skills' "$W_LOG" | head -3 | tr '\n' ' ')"
  fi
  if [[ -f "$SENTINEL" ]]; then pass "G5 host sentinel survived init: ${SENTINEL}"; else fail "G5 host sentinel is GONE: ${SENTINEL}"; fi
  if [[ -d "${HOME}/.claude/skills" && ! -L "${HOME}/.claude/skills" ]]; then pass "G6 host ~/.claude/skills is still a real directory"; else fail "G6 host ~/.claude/skills was replaced" "$(ls -ld "${HOME}/.claude/skills" 2>&1)"; fi
  if cmp -s "${T}/settings.json.orig" "${HOME}/.claude/settings.json"; then pass "G7 host ~/.claude/settings.json byte-identical after init"; else fail "G7 host ~/.claude/settings.json was overwritten" "now: $(head -c 120 "${HOME}/.claude/settings.json" 2>&1 | tr '\n' ' ')"; fi
  if cmp -s "${T}/CLAUDE.md.orig" "${HOME}/.claude/CLAUDE.md"; then pass "G8 host ~/.claude/CLAUDE.md byte-identical after init"; else fail "G8 host ~/.claude/CLAUDE.md was overwritten" "now: $(head -c 120 "${HOME}/.claude/CLAUDE.md" 2>&1 | tr '\n' ' ')"; fi
  if [[ ! -e "${HOME}/.claude/.claude.json.seed" ]]; then pass "G9 init wrote no .claude.json.seed into the host ~/.claude"; else fail "G9 init created ${HOME}/.claude/.claude.json.seed on the host"; fi
  # shellcheck disable=SC2088  # literal text init prints, not a path
  if grep -qF "~/.claude/settings.json sits inside the cage-config mount /home/agent/.claude;" "$W_LOG" \
     && grep -qF "~/.claude/CLAUDE.md sits inside the cage-config mount /home/agent/.claude;" "$W_LOG" \
     && grep -qF "~/.claude/.claude.json.seed sits inside the cage-config mount /home/agent/.claude;" "$W_LOG" \
     && grep -qF "~/.claude/projects sits inside the cage-config mount /home/agent/.claude;" "$W_LOG" \
     && grep -qF "~/.claude/sessions sits inside the cage-config mount /home/agent/.claude;" "$W_LOG"; then
    pass "G10 init printed the skip lines for settings.json, CLAUDE.md, .claude.json.seed, projects and sessions"
  else
    fail "G10 a settings.json/CLAUDE.md/.claude.json.seed/projects/sessions skip line is absent from rc up output" "WARNING lines: $(grep -F 'WARNING' "$W_LOG" | head -5 | tr '\n' ' ')"
  fi
  _g11_ok=1
  for _d in projects sessions; do
    if [[ ! -d "${HOME}/.claude/${_d}" || -L "${HOME}/.claude/${_d}" ]] \
       || ! ls -A "${HOME}/.claude/${_d}" | cmp -s "${T}/${_d}.ls.orig" -; then
      _g11_ok=0
    fi
  done
  if [[ $_g11_ok -eq 1 ]]; then pass "G11 host ~/.claude/projects and sessions untouched (no legacy-volume link)"; else fail "G11 init linked into host ~/.claude/projects or sessions" "$(ls -la "${HOME}/.claude/projects" "${HOME}/.claude/sessions" 2>&1 | tr '\n' ' ')"; fi
fi

echo ""
if [[ $FAILS -eq 0 ]]; then echo "ALL LIVE CHECKS PASSED"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"
exit 1
