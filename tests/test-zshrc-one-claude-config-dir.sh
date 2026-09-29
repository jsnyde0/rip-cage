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
#   Z3  no multiplexer                         -> CLAUDE_CONFIG_DIR unchanged
#   Z4  per-agent git author still derives from the handle (herdr, tmux)
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

# run_zshrc <env assignments...> -> prints "<CLAUDE_CONFIG_DIR>|<GIT_AUTHOR_NAME>"
run_zshrc() {
  env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" TERM=xterm-256color \
    CLAUDE_CONFIG_DIR="$IMAGE_CFG" "$@" \
    zsh -f -c "source '$ZSHRC' >/dev/null 2>&1; print -r -- \"\${CLAUDE_CONFIG_DIR:-UNSET}|\${GIT_AUTHOR_NAME:-UNSET}\"" 2>/dev/null
}

out=$(run_zshrc HERDR_SESSION=herdr-sess)
if [[ "${out%%|*}" == "$IMAGE_CFG" ]]; then pass "Z1 herdr named session: CLAUDE_CONFIG_DIR stays ${IMAGE_CFG}"; else fail "Z1 herdr named session diverged CLAUDE_CONFIG_DIR" "got '${out%%|*}'"; fi
if [[ "${out##*|}" == "herdr-sess" ]]; then pass "Z4 herdr: GIT_AUTHOR_NAME=herdr-sess"; else fail "Z4 herdr: GIT_AUTHOR_NAME not derived" "got '${out##*|}'"; fi

out=$(run_zshrc TMUX=/tmp/tmux-1000/default,1,0)
if [[ "${out%%|*}" == "$IMAGE_CFG" ]]; then pass "Z2 tmux: CLAUDE_CONFIG_DIR stays ${IMAGE_CFG}"; else fail "Z2 tmux diverged CLAUDE_CONFIG_DIR" "got '${out%%|*}'"; fi
if [[ "${out##*|}" == "tmux-sess" ]]; then pass "Z4 tmux: GIT_AUTHOR_NAME=tmux-sess"; else fail "Z4 tmux: GIT_AUTHOR_NAME not derived" "got '${out##*|}'"; fi

out=$(run_zshrc)
if [[ "${out%%|*}" == "$IMAGE_CFG" ]]; then pass "Z3 no multiplexer: CLAUDE_CONFIG_DIR stays ${IMAGE_CFG}"; else fail "Z3 no multiplexer changed CLAUDE_CONFIG_DIR" "got '${out%%|*}'"; fi

echo "=== test-zshrc-one-claude-config-dir.sh: ${FAILS} failure(s) ==="
[[ "$FAILS" -eq 0 ]]
