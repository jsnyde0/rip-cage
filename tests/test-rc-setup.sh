#!/usr/bin/env bash
# tests/test-rc-setup.sh — rip-cage-9oyh §4 gap-fill: `rc setup` (previously
# untested — the coverage-gap inventory in
# docs/2026-07-08-rc-decomposition-map.md notes "setup verb -- no test
# drives `rc setup` (only manifest-layer indirection)"). The single-shot
# zsh/bash/fish/unset cases are golden-mastered in
# tests/golden-master/cases.sh; this file covers the IDEMPOTENCY behavior
# (a second run once shell completions are already configured), which needs
# a real write between two invocations and so doesn't fit the golden-master
# stdout/stderr/exit-only capture model.
#
# Wired into tests/run-host.sh (host-only tier).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GM_LIB="${SCRIPT_DIR}/golden-master/lib"
# shellcheck source=golden-master/lib/sandbox.sh
source "${GM_LIB}/sandbox.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# S1: idempotency -- once ~/.zshrc already has the `rc completions` eval
# line (whether from a real accepted `rc setup` prompt or hand-edited), a
# second `rc setup` detects it and exits 0 WITHOUT re-prompting.
# ---------------------------------------------------------------------------
gm_sandbox_reset
mkdir -p "$GM_HOME"
cat > "${GM_HOME}/.zshrc" <<'EOF'
# pre-existing zshrc
eval "$(rc completions zsh)"
EOF

GM_SHELL_OVERRIDE="/bin/zsh" gm_capture setup

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "S1: idempotent second run exits 0"
else
  fail "S1 exit code" "expected 0, got $GM_EXIT. stdout=$GM_OUT stderr=$GM_ERR"
fi
if echo "$GM_OUT" | grep -qi "already configured"; then
  pass "S1: idempotent second run reports 'already configured' (no re-prompt)"
else
  fail "S1 message" "expected an 'already configured' message; got stdout=$GM_OUT"
fi

# The file must be UNCHANGED (content-equality, not mtime -- rip-cage-woow
# mtime-flake lesson in .claude/harness.md: mtime is a flaky idempotency
# proxy, content equality is the true invariant).
BEFORE_CONTENT=$(cat "${GM_HOME}/.zshrc")
GM_SHELL_OVERRIDE="/bin/zsh" gm_capture setup
AFTER_CONTENT=$(cat "${GM_HOME}/.zshrc")
if [[ "$BEFORE_CONTENT" == "$AFTER_CONTENT" ]]; then
  pass "S1b: idempotent second run does not rewrite ~/.zshrc (content-equality)"
else
  fail "S1b content-equality" "~/.zshrc changed across idempotent re-runs"
fi

# ---------------------------------------------------------------------------
# S2: idempotency detection is RELAXED (substring match, not exact-line) --
# a user-modified eval line (e.g. with extra flags/comment) still counts as
# "already configured", per the relaxed-pattern comment at rc's setup
# idempotency check ("catches user-modified eval lines").
# ---------------------------------------------------------------------------
gm_sandbox_reset
mkdir -p "$GM_HOME"
cat > "${GM_HOME}/.zshrc" <<'EOF'
# user customized this line
eval "$(rc completions zsh)"  # added manually, not via rc setup
EOF
GM_SHELL_OVERRIDE="/bin/zsh" gm_capture setup
if [[ "$GM_EXIT" -eq 0 ]] && echo "$GM_OUT" | grep -qi "already configured"; then
  pass "S2: relaxed idempotency match catches a user-modified eval line"
else
  fail "S2 relaxed match" "expected 'already configured' + exit 0; got exit=$GM_EXIT stdout=$GM_OUT"
fi

# ---------------------------------------------------------------------------
# S3: bash uses .bashrc when present (mirrors S1 for the bash branch of
# cmd_setup's config-file heuristic).
# ---------------------------------------------------------------------------
gm_sandbox_reset
mkdir -p "$GM_HOME"
cat > "${GM_HOME}/.bashrc" <<'EOF'
eval "$(rc completions bash)"
EOF
GM_SHELL_OVERRIDE="/bin/bash" gm_capture setup
if [[ "$GM_EXIT" -eq 0 ]] && echo "$GM_OUT" | grep -qi "already configured"; then
  pass "S3: bash idempotency via ~/.bashrc"
else
  fail "S3 bash idempotency" "expected 'already configured' + exit 0; got exit=$GM_EXIT stdout=$GM_OUT"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
