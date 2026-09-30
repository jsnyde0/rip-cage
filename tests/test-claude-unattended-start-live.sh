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
#   U4/U9  no "make auto mode your default?" nudge (screen leg) AND the
#          mechanism leg, which bites under the fake token: in the guest
#          CLAUDE_CONFIG_DIR is /home/agent/.claude (image ENV) and
#          /home/agent/.claude/.claude.json carries hasSeenAutoDefaultNudge:true
#          (init writes it from the seed on every boot; rip-cage-jimf.9)
#   U5/U10 the prompt rendered (the bypass-permissions status line)
#   U11    the host ~/.claude.json is still read-only in the guest
#   U12    control: the same probe against a config dir whose settings.json
#          is the cage's minus skipDangerousModePermissionPrompt DOES show the
#          accept dialog -- proves U3/U8 can catch it
#   U13    control through the image ENV: with the /workspace trust entry
#          removed from the writable ~/.claude/.claude.json only (the host file
#          still trusts it), the inherited-env claude DOES render the
#          workspace-trust dialog -- proves claude reads
#          $CLAUDE_CONFIG_DIR/.claude.json (the file init writes), not
#          /home/agent/.claude.json. The file is restored afterwards. The
#          prep first asserts the pre-edit file HAD the /workspace key, so the
#          delete is a real edit.
#   U14    third boot (stop + resume) with the /workspace trust key removed
#          from the HOST ~/.claude.json (a fresh user's shape): init still seeds
#          projects["/workspace"].hasTrustDialogAccepted into the writable
#          ~/.claude/.claude.json (mechanism leg, with the host file confirmed
#          trust-less), and the probe shows claude's screen with no
#          workspace-trust dialog (rip-cage-7812). Red if init's seed step
#          drops the trust answer.
#
# No real credential by default: the CCTOK secret is a fake of the setup-token
# shape; nothing here reaches the API. LIMIT, measured 2026-09-29: the auto-mode
# nudge renders only under a real login, so under the fake token the SCREEN leg
# of U4/U9 cannot fire (it passes vacuously); the mechanism leg and U13 are what
# bite here. Opt-in real-auth run: RC_JIMF_CCTOK_FILE=<path to a setup-token
# file> copies that file in as the CCTOK secret (never printed, never logged;
# the probe screens land in $RC_JIMF_LOG_DIR and carry no token). Then the
# screen leg bites. Probe transcripts land in $RC_JIMF_LOG_DIR
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

# The short scratch root (symlink-resolved: msb does not follow a host-side
# symlink in a mount source), so the cage name is "rc-live-jimf.XXXXXX-<subdir>",
# a shape the scratch-cage registry persists and sweeps (rip-cage-znws).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
T=$(_host_scratch_mktemp_d rc-live-jimf)
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
if [[ -n "${RC_JIMF_CCTOK_FILE:-}" ]]; then
  # Opt-in real-auth seam: the file is copied, never read into the session or echoed.
  [[ -f "$RC_JIMF_CCTOK_FILE" ]] || { echo "FATAL: RC_JIMF_CCTOK_FILE is not a file"; exit 1; }
  ( umask 077; cp "$RC_JIMF_CCTOK_FILE" "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK" )
  _auth_note=" (real token)"
  echo "auth=real-token-file (screen leg bites)"
else
  ( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK" )
  _auth_note=" (vacuous under the fake token -- see LIMIT)"
  echo "auth=fake-token (screen leg of the nudge check is vacuous)"
fi

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
  local _cd _nf
  _cd=$(gexec 30 printenv CLAUDE_CONFIG_DIR 2>/dev/null | tr -d '\r\n')
  _nf=$(gexec 30 jq -r '.hasSeenAutoDefaultNudge' /home/agent/.claude/.claude.json 2>/dev/null | tr -d '\r\n')
  if [[ "$_cd" == "/home/agent/.claude" && "$_nf" == "true" ]]; then
    pass "${_nud}m ${_label}: mechanism -- CLAUDE_CONFIG_DIR=${_cd}, ~/.claude/.claude.json hasSeenAutoDefaultNudge=true"
  else
    fail "${_nud}m ${_label}: mechanism leg" "CLAUDE_CONFIG_DIR='${_cd}' hasSeenAutoDefaultNudge='${_nf}'"
  fi
  if grep -qiE "auto mode your default" "$_out"; then fail "${_nud} ${_label}: 'make auto mode your default?' nudge appeared" "$_out"; else pass "${_nud} ${_label}: no auto-mode-default nudge on screen${_auth_note}"; fi
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

# --- U13: control -- claude, with the IMAGE's inherited env, reads
# /home/agent/.claude/.claude.json ------------------------------------------
# The host file (mounted at /home/agent/.claude.json) still trusts /workspace.
# Temporarily drop the trust entry from the WRITABLE ~/.claude/.claude.json only,
# run the probe with the inherited environment (no CLAUDE_CONFIG_DIR override),
# expect the workspace-trust dialog, restore. If claude read the host mount
# instead, /workspace would stay trusted and no dialog would render. The
# edited file is checked non-empty and still carrying the nudge flag before
# the probe runs, so an empty/garbled file cannot produce the dialog by itself.
CTRL2="${LOG_DIR}/probe-control-trust.txt"
_u13_prep=$(gexec 30 sh -c 'cd /home/agent/.claude && jq -e ".projects | has(\"/workspace\")" .claude.json >/dev/null && cp .claude.json /tmp/jimf-cj.bak && jq "del(.projects[\"/workspace\"])" .claude.json > /tmp/jimf-cj.new && jq -e ".hasSeenAutoDefaultNudge == true and ((.projects // {}) | has(\"/workspace\") | not)" /tmp/jimf-cj.new >/dev/null && cp /tmp/jimf-cj.new .claude.json && echo PREPPED' 2>/dev/null | tr -d '\r\n')
if [[ "$_u13_prep" != "PREPPED" ]]; then
  fail "U13 control: could not prepare the trust-less ~/.claude/.claude.json in the guest" "prep=${_u13_prep:-<none>}"
else
  gexec 60 python3 -c "$(cat "$PROBE")" 25 /workspace > "$CTRL2" 2>&1
  gexec 30 sh -c 'cp /tmp/jimf-cj.bak /home/agent/.claude/.claude.json' >/dev/null 2>&1
  if ! grep -qE "Claude Code|Bypass Permissions mode|bypass permissions on" "$CTRL2"; then
    fail "U13 control: probe captured no claude screen (no positive sentinel)" "$(head -c 200 "$CTRL2" | tr '\n' ' ')"
  elif grep -qiE "trust this folder|Quick safety check|trust the files" "$CTRL2"; then
    pass "U13 control: with the trust entry gone from ~/.claude/.claude.json (host file still trusts), the inherited-env claude renders the trust dialog -- it reads \$CLAUDE_CONFIG_DIR/.claude.json"
  else
    fail "U13 control: no workspace-trust dialog with the trust entry removed from ~/.claude/.claude.json" "$CTRL2"
  fi
fi

# --- U14: a host seed WITHOUT the /workspace trust key -- boot 3 -----------
# A fresh user's ~/.claude.json never trusted /workspace. Drop the key from the
# host file (this test's own temp file; the guest sees it read-only), stop,
# resume -- init re-snapshots the seed and must seed the trust answer itself.
jq 'del(.projects["/workspace"])' "$HOME/.claude.json" > "${T}/cj-notrust.json" \
  && mv -f "${T}/cj-notrust.json" "$HOME/.claude.json"
perl -e 'alarm shift; exec @ARGV' 120 msb stop "$NAME" > "${LOG_DIR}/stop-notrust.log" 2>&1
"$RC" up "$WS" < /dev/null > "${LOG_DIR}/up-notrust.log" 2>&1; _u14_rc=$?
if [[ "$_u14_rc" -ne 0 ]]; then
  fail "U14 no-trust seed: rc up exit ${_u14_rc}" "log tail: $(tail -5 "${LOG_DIR}/up-notrust.log" | tr '\n' ' ')"
else
  _u14_host=$(gexec 30 jq -c '(.projects // {}) | has("/workspace")' /home/agent/.claude.json 2>/dev/null | tr -d '\r\n')
  _u14_seed=$(gexec 30 jq -c '.projects["/workspace"].hasTrustDialogAccepted' /home/agent/.claude/.claude.json 2>/dev/null | tr -d '\r\n')
  # Pinned to THIS boot: init's R4b success line must be in this rc up's own
  # log, so a copy left from an earlier boot cannot pass the leg.
  _u14_wrote=no
  grep -qF "Wrote ~/.claude/.claude.json from the seed" "${LOG_DIR}/up-notrust.log" && _u14_wrote=yes
  if [[ "$_u14_host" == "false" && "$_u14_seed" == "true" && "$_u14_wrote" == "yes" ]]; then
    pass "U14m no-trust seed: mechanism -- host ~/.claude.json has no /workspace key; this boot's init rewrote ~/.claude/.claude.json with /workspace hasTrustDialogAccepted=true"
  else
    fail "U14m no-trust seed: mechanism leg" "host has /workspace='${_u14_host}' guest trust='${_u14_seed}' rewritten-this-boot='${_u14_wrote}'"
  fi
  CTRL3="${LOG_DIR}/probe-notrust.txt"
  gexec 60 python3 -c "$(cat "$PROBE")" 25 /workspace > "$CTRL3" 2>&1
  if ! grep -qE "Claude Code|Bypass Permissions mode|bypass permissions on" "$CTRL3"; then
    fail "U14 no-trust seed: probe captured no claude screen (no positive sentinel)" "$(head -c 200 "$CTRL3" | tr '\n' ' ')"
  elif grep -qiE "trust this folder|Quick safety check|trust the files" "$CTRL3"; then
    fail "U14 no-trust seed: the workspace-trust dialog rendered -- init did not seed the /workspace trust answer" "$CTRL3"
  else
    pass "U14 no-trust seed: claude's screen ($(wc -c < "$CTRL3" | tr -d ' ') bytes) shows no workspace-trust dialog"
  fi
fi

echo ""
if [[ $FAILS -eq 0 ]]; then echo "ALL LIVE CHECKS PASSED"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"
exit 1
