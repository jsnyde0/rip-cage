#!/usr/bin/env bash
# tests/test-claude-unattended-start-live.sh -- container-tier proof that
# claude on the BASE image reaches its prompt unattended, past the
# bypass-permissions accept dialog, on every cold boot of a template-shaped
# cage (rip-cage-jimf). The auto-mode nudge is checked too, but see LIMIT.
#
# One scratch cage from the shipped template (host ~/.claude.json mounted
# read-only, as the template ships it), under a temp HOME whose .claude.json
# carries neither bypassPermissionsModeAccepted nor hasSeenAutoDefaultNudge
# but does trust /workspace -- the operator's measured shape. (An untrusted
# /workspace stops claude earlier, at the workspace-trust dialog; that dialog
# is not this bead's.) tests/fixtures/claude-pty-probe.py spawns a
# bare `claude` in a pseudo-terminal inside the guest, answers nothing, and
# prints what rendered. Two boots (create, then stop + resume):
#   U1/U6  rc up exit 0
#   U2/U7  positive sentinel: the probe captured claude's own screen
#   U3/U8  no bypass-permissions accept dialog ("Yes, I accept")
#   U4/U9  no "make auto mode your default?" nudge
#   U5/U10 the prompt rendered (the bypass-permissions status line)
#   U11    the host ~/.claude.json is still read-only in the guest
#   U12    control: the same probe against a config dir whose settings.json
#          is the cage's minus skipDangerousModePermissionPrompt DOES show the
#          accept dialog -- proves U3/U8 can catch it
#
# No real credential: the CCTOK secret is a fake of the setup-token shape;
# nothing here reaches the API. LIMIT, measured 2026-09-29: the auto-mode
# nudge renders only under a real login, so under the fake token U4/U9 cannot
# fire -- they pass vacuously here and bite only on a real-auth run. Probe transcripts land in $RC_JIMF_LOG_DIR
# (default: the temp dir, removed at exit) for the ship-record.
#
# Image: RC_IMAGE, REQUIRED to be an explicit scratch tag, never
# rip-cage:latest (same guards as tests/test-init-mount-guard-live.sh).
# Build one: RC_IMAGE=<tag> rc build --file cage/Dockerfile
#
# NEEDS_CONTAINER (registered in tests/run-host.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"
PROBE="${SCRIPT_DIR}/fixtures/claude-pty-probe.py"
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
T=$(mktemp -d "${_tmp_root}/rc-live-jimf.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
LOG_DIR="${RC_JIMF_LOG_DIR:-$T}"
mkdir -p "$LOG_DIR"

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/xdg"
export MSB_HOME="${REAL_HOME}/.microsandbox"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/skills"
# The operator's shape: onboarding done, neither dialog flag present.
echo '{"hasCompletedOnboarding": true, "theme": "dark", "projects": {"/workspace": {"hasTrustDialogAccepted": true}}}' > "$HOME/.claude.json"
[[ -e "${REAL_HOME}/.docker" ]] && ln -sfn "${REAL_HOME}/.docker" "${HOME}/.docker"
unset CCTOK

WS="${T}/ws"
mkdir -p "$WS"
git -C "$WS" init -q
echo "# unattended claude start proof" > "$WS/README"
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
if ! grep -qF "\"${HOME}/.claude.json:/home/agent/.claude.json:ro\"" "$CONF"; then
  echo "FATAL: the template no longer mounts ~/.claude.json read-only; this test's premise moved"
  exit 1
fi
( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK" )

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
scratch_cage_register "$NAME"
echo "cage=${NAME} image=${IMAGE} logs=${LOG_DIR}"

gexec() {
  local _secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$_secs" msb exec "$NAME" -- "$@" < /dev/null
}

# probe_boot <label> <n-up> <n-sentinel> <n-accept> <n-nudge> <n-prompt> <up-log>
probe_boot() {
  local _label="$1" _up="$2" _sen="$3" _acc="$4" _nud="$5" _pr="$6" _uplog="$7" _rc
  _rc=$(cat "${_uplog}.rc")
  if [[ "$_rc" -eq 0 ]]; then pass "${_up} ${_label}: rc up (init included) exit 0"; else fail "${_up} ${_label}: rc up exit ${_rc}" "log tail: $(tail -5 "$_uplog" | tr '\n' ' ')"; return; fi
  local _out="${LOG_DIR}/probe-${_label}.txt"
  gexec 60 python3 -c "$(cat "$PROBE")" 25 /workspace > "$_out" 2>&1
  # Positive sentinel first: every absence below is only meaningful if the
  # probe captured claude's own screen.
  if grep -qE "Claude Code|Bypass Permissions mode|bypass permissions on" "$_out"; then pass "${_sen} ${_label}: probe captured claude's screen ($(wc -c < "$_out" | tr -d ' ') bytes)"; else fail "${_sen} ${_label}: probe captured no claude output" "$(head -c 300 "$_out" | tr '\n' ' ')"; return; fi
  if grep -qF "Yes, I accept" "$_out"; then fail "${_acc} ${_label}: bypass-permissions accept dialog appeared" "$_out"; else pass "${_acc} ${_label}: no bypass-permissions accept dialog"; fi
  if grep -qiE "auto mode your default" "$_out"; then fail "${_nud} ${_label}: 'make auto mode your default?' nudge appeared" "$_out"; else pass "${_nud} ${_label}: no auto-mode-default nudge (vacuous under the fake token -- see LIMIT)"; fi
  if grep -qiE "bypass permissions on" "$_out"; then pass "${_pr} ${_label}: prompt rendered (bypass permissions on)"; else fail "${_pr} ${_label}: prompt status line not seen" "$_out"; fi
}

# --- boot 1: create -------------------------------------------------------
"$RC" up "$WS" < /dev/null > "${LOG_DIR}/up-create.log" 2>&1; echo $? > "${LOG_DIR}/up-create.log.rc"
probe_boot create U1 U2 U3 U4 U5 "${LOG_DIR}/up-create.log"

# --- boot 2: stop, then resume (a fresh kernel boot under msb) ------------
perl -e 'alarm shift; exec @ARGV' 120 msb stop "$NAME" > "${LOG_DIR}/stop.log" 2>&1
"$RC" up "$WS" < /dev/null > "${LOG_DIR}/up-resume.log" 2>&1; echo $? > "${LOG_DIR}/up-resume.log.rc"
probe_boot resume U6 U7 U8 U9 U10 "${LOG_DIR}/up-resume.log"

# --- U11: the human's binding decision still holds -------------------------
# A real write attempt, not test -w: access() on a virtiofs mount need not
# report the ro flag. The fixture is this test's own temp file.
# The guest prints REFUSED only when its own write failed, so an msb exec
# error or timeout cannot pass this check.
_u11=$(gexec 30 sh -c 'if echo x >> /home/agent/.claude.json 2>/dev/null; then echo WROTE; else echo REFUSED; fi' 2>/dev/null)
if gexec 30 jq -e '.hasCompletedOnboarding == true' /home/agent/.claude.json >/dev/null 2>&1 \
   && [[ "$_u11" == "REFUSED" ]]; then
  pass "U11 host ~/.claude.json is read-only in the guest"
else
  fail "U11 host ~/.claude.json is writable (or unreadable) in the guest"
fi

# --- U12: control -- the probe catches the dialog when the key is absent ---
# A second claude config dir in the guest: the cage's own settings.json with
# the key deleted, and the guest's .claude.json. (--settings '{"...": false}'
# does not override a true from settings.json, measured 2026-09-29.)
CTRL="${LOG_DIR}/probe-control.txt"
gexec 30 sh -c 'mkdir -p /tmp/jimf-ctrl && jq "del(.skipDangerousModePermissionPrompt)" /home/agent/.claude/settings.json > /tmp/jimf-ctrl/settings.json && cp /home/agent/.claude.json /tmp/jimf-ctrl/.claude.json' >/dev/null 2>&1
gexec 60 sh -c 'CLAUDE_CONFIG_DIR=/tmp/jimf-ctrl exec python3 -c "$1" 25 /workspace' _ "$(cat "$PROBE")" > "$CTRL" 2>&1
if grep -qF "Yes, I accept" "$CTRL"; then
  pass "U12 control: with skipDangerousModePermissionPrompt absent, the accept dialog appears"
else
  fail "U12 control: the probe did not catch the accept dialog with the key absent -- U3/U8 prove nothing" "$CTRL"
fi

echo ""
if [[ $FAILS -eq 0 ]]; then echo "ALL LIVE CHECKS PASSED"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"
exit 1
