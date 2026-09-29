#!/usr/bin/env bash
# tests/test-zshrc-one-claude-config-dir.sh -- HOST-ONLY test that the base
# image's ~/.zshrc (cage/agent/zshrc) leaves CLAUDE_CONFIG_DIR alone under
# every multiplexer (rip-cage-r0jh).
#
# WHY: the base image has ONE claude config dir, /home/agent/.claude (image ENV,
# seeded by init every boot with the workspace trust and hasSeenAutoDefaultNudge;
# rip-cage-jimf.9). The zshrc used to repoint CLAUDE_CONFIG_DIR at
# ~/.claude-sessions/<handle> whenever $TMUX or $HERDR_SESSION was set, a dir
# nothing on the base image seeds -- so a zsh pane under tmux or a named herdr
# session met claude's first-run screens instead of its prompt (measured live
# 2026-09-29). Per-session dirs are the examples/claude recipe's business: its
# wrapper derives and seeds them itself, treating the image default as unset
# (tests/test-claude-recipe-bypass-preaccept.sh C9).
#
# Method: source the real cage/agent/zshrc in `zsh -f` under a temp HOME, with
# the image's CLAUDE_CONFIG_DIR and the multiplexer identity env set, and a
# stub `tmux` on PATH that answers `display-message -p '#S'`.
#   Z1  herdr named session ($HERDR_SESSION)   -> CLAUDE_CONFIG_DIR unchanged
#   Z2  tmux ($TMUX + session name)            -> CLAUDE_CONFIG_DIR unchanged
#   Z3  no multiplexer                         -> CLAUDE_CONFIG_DIR unchanged,
#                                                 git author/committer unset
#   Z4  herdr: GIT_AUTHOR_NAME and GIT_COMMITTER_NAME = $HERDR_SESSION
#   Z5  tmux:  GIT_AUTHOR_NAME and GIT_COMMITTER_NAME = tmux session name
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZSHRC="${SCRIPT_DIR}/../cage/agent/zshrc"
IMAGE_CFG=/home/agent/.claude

command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not on PATH"; exit 0; }
[[ -f "$ZSHRC" ]] || { echo "FAIL: ${ZSHRC} missing"; exit 1; }

FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ -- $2}"; FAILS=$((FAILS + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin"
# shellcheck disable=SC2016  # $1 expands in the stub, on purpose
printf '#!/bin/sh\n[ "$1" = display-message ] && echo tmux-sess\n' > "$T/bin/tmux"
chmod +x "$T/bin/tmux"

# run_zshrc <env assignments...>
#   -> prints "<CLAUDE_CONFIG_DIR>|<GIT_AUTHOR_NAME>|<GIT_COMMITTER_NAME>"
run_zshrc() {
  env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" TERM=xterm-256color \
    CLAUDE_CONFIG_DIR="$IMAGE_CFG" "$@" \
    zsh -f -c "source '$ZSHRC' >/dev/null 2>&1; print -r -- \"\${CLAUDE_CONFIG_DIR:-UNSET}|\${GIT_AUTHOR_NAME:-UNSET}|\${GIT_COMMITTER_NAME:-UNSET}\"" 2>/dev/null
}

# check_case <id-cfg> <id-git> <label> <want-git> <env assignments...>
check_case() {
  local _idc="$1" _idg="$2" _label="$3" _want="$4" _out _cfg _git
  shift 4
  _out=$(run_zshrc "$@")
  _cfg="${_out%%|*}"
  _git="${_out#*|}"
  if [[ "$_cfg" == "$IMAGE_CFG" ]]; then pass "${_idc} ${_label}: CLAUDE_CONFIG_DIR stays ${IMAGE_CFG}"; else fail "${_idc} ${_label}: CLAUDE_CONFIG_DIR changed" "got '${_cfg}'"; fi
  if [[ "$_git" == "${_want}|${_want}" ]]; then pass "${_idg} ${_label}: GIT_AUTHOR_NAME and GIT_COMMITTER_NAME = ${_want}"; else fail "${_idg} ${_label}: git author/committer" "want '${_want}|${_want}', got '${_git}'"; fi
}

check_case Z1 Z4 "herdr named session" herdr-sess HERDR_SESSION=herdr-sess
check_case Z2 Z5 "tmux" tmux-sess TMUX=/tmp/tmux-1000/default,1,0
check_case Z3 Z3 "no multiplexer" UNSET

echo "=== test-zshrc-one-claude-config-dir.sh: ${FAILS} failure(s) ==="
[[ "$FAILS" -eq 0 ]]
