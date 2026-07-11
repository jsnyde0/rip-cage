#!/usr/bin/env bash
# tests/test-msb-claude-home-resume.sh -- effect-based resume verification
# for rip-cage-xuy8 (S3 of the msb migration epic rip-cage-tsf2).
#
# This is the bead's "harness target" made literal: plant REAL Claude Code
# session state, cold-recreate the cage over the SAME persistent host mount
# (the r8jl cheap-recreate pattern -- rip-cage-r8jl found overlay-only state
# is discarded but named/mounted-dir state survives cold `--replace`), boot
# again, and read the planted content back -- never dir-listing/exit-0 alone.
#
# S6's rc resume verb does not exist yet, so this drives `msb` DIRECTLY,
# exactly as instructed. It exercises the ACTUAL shipped
# claude-session-wrapper.sh (cage/substrate/claude-session-wrapper.sh) --
# mounted and invoked as-is, not reimplemented -- and the ACTUAL shipped
# _seed_claude_home_dirs() (cli/up.sh, sourced from `rc`) for the fix side.
#
# SCENARIO A (fix present): _seed_claude_home_dirs pre-creates projects/ and
#   sessions/ in the claude-home root BEFORE the first mount/boot. A planted
#   codeword survives a cold cage recreate: (a) the host-side .jsonl
#   transcript itself contains the real codeword post-recreate (the
#   authoritative, non-LLM-mediated assertion), and (b) `claude --resume`
#   in the recreated cage recalls it (functional-path corroboration).
#
# SCENARIO B (fix absent -- negative control): claude-home root exists but
#   its projects/sessions dirs are NOT pre-created (mirrors the exact
#   pre-rip-cage-xuy8 footgun). The wrapper only symlinks
#   ~/.claude/projects|sessions into its per-session config dir when they
#   ALREADY EXIST at wrapper-run time (cage/substrate/claude-session-wrapper.sh);
#   absent, it seeds fresh copies in the guest's EPHEMERAL per-session dir
#   instead. That state is NOT on the virtiofs host mount, so a cold
#   `--replace` recreate (which discards guest overlay writes, per
#   rip-cage-r8jl) genuinely loses it: no host-side transcript is created,
#   and `claude --resume` against the recreated cage cannot recover the
#   codeword.
#
# SAFETY (mirrors rip-cage-1ujn): NEVER mounts or writes the real ~/.claude.
# Builds two disposable scratch claude homes (mktemp -d), seeds credentials
# by copying (never printing) the real .credentials.json + minimal
# non-token claude.json fields. Real ~/.claude is verified untouched
# (mtime unchanged) at the end.
#
# NEEDS_CONTAINER + NEEDS_MSB + a real, authenticated host Claude Code
# session. Self-skips (exit 0, SKIP: ...) when any prerequisite is missing --
# never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
WRAPPER_SRC="${REPO_ROOT}/cage/substrate/claude-session-wrapper.sh"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available -- skipping $(basename "$0")"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no pre-built ${IMAGE} docker image -- skipping $(basename "$0") (run: rc build)"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: ${IMAGE} not loaded into msb -- skipping $(basename "$0") (run: rc build, which msb-loads it)"
  exit 0
fi
if [[ ! -s "${HOME}/.claude/.credentials.json" ]]; then
  echo "SKIP: no host ~/.claude/.credentials.json (host claude not authed) -- skipping $(basename "$0")"
  exit 0
fi
if [[ ! -f "$WRAPPER_SRC" ]]; then
  echo "SKIP: ${WRAPPER_SRC} missing -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available -- skipping $(basename "$0")"
  exit 0
fi

REAL_CLAUDE_MTIME_BEFORE=$(stat -f "%m" "${HOME}/.claude/.credentials.json" 2>/dev/null || stat -c "%Y" "${HOME}/.claude/.credentials.json" 2>/dev/null)

SBX_A="xuy8-resume-a-$$"
SBX_B="xuy8-resume-b-$$"
SCRATCH_A=""
SCRATCH_B=""

cleanup() {
  msb remove -f "$SBX_A" >/dev/null 2>&1 || true
  msb remove -f "$SBX_B" >/dev/null 2>&1 || true
  [[ -n "$SCRATCH_A" ]] && rm -rf "$SCRATCH_A"
  [[ -n "$SCRATCH_B" ]] && rm -rf "$SCRATCH_B"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build a scratch claude home. NEVER touches real ~/.claude.
#   $1 -- scratch base dir (already created by mktemp -d)
# Leaves $1/claude-dir (mount source for /home/agent/.claude) and
# $1/claude.json (mount source for /home/agent/.claude.json) populated.
# ---------------------------------------------------------------------------
_build_scratch_claude_home() {
  local _base="$1"
  mkdir -p "${_base}/claude-dir"
  cp "${HOME}/.claude/.credentials.json" "${_base}/claude-dir/.credentials.json"
  chmod 600 "${_base}/claude-dir/.credentials.json"
  if [[ -f "${HOME}/.claude.json" ]]; then
    jq -c '{hasCompletedOnboarding, oauthAccount}' "${HOME}/.claude.json" > "${_base}/claude.json"
  else
    echo '{}' > "${_base}/claude.json"
  fi
}

NET_RULES=(
  --net-default deny
  --net-rule "allow@api.anthropic.com:tcp:443"
  --net-rule "allow@mcp-proxy.anthropic.com:tcp:443"
  --net-rule "allow@http-intake.logs.us5.datadoghq.com:tcp:443"
)

CODEWORD_A="XUY8POSITIVE-$$-${RANDOM}"
CODEWORD_B="XUY8NEGATIVE-$$-${RANDOM}"

# ===========================================================================
# SCENARIO A -- fix present: _seed_claude_home_dirs pre-creates projects/
# and sessions/ BEFORE the claude-home root is ever mounted.
# ===========================================================================
echo ""
echo "=== SCENARIO A (fix present): plant -> cold-recreate -> read back ==="
SCRATCH_A=$(mktemp -d)
_build_scratch_claude_home "$SCRATCH_A"

# Drive the ACTUAL shipped helper (cli/up.sh, sourced from rc), not a
# reimplementation of the mkdir -p -- this is the exact fix under test.
bash -c "source '${RC}'; _seed_claude_home_dirs '${SCRATCH_A}/claude-dir'"

if [[ -d "${SCRATCH_A}/claude-dir/projects" && -d "${SCRATCH_A}/claude-dir/sessions" ]]; then
  pass "A0: _seed_claude_home_dirs pre-created projects/+sessions/ before first mount"
else
  fail "A0: pre-create did not happen" "$(ls -la "${SCRATCH_A}/claude-dir")"
fi

A_PLANT_OUT=$(msb run --name "$SBX_A" --replace --timeout 90s "${NET_RULES[@]}" \
  -v "${SCRATCH_A}/claude-dir:/home/agent/.claude" \
  --mount-file "${SCRATCH_A}/claude.json:/home/agent/.claude.json" \
  --mount-file "${WRAPPER_SRC}:/home/agent/.rc-context/claude-wrapper.sh:ro" \
  -w /home/agent "$IMAGE" -- sh -c \
  "bash /home/agent/.rc-context/claude-wrapper.sh -p 'Remember this codeword: ${CODEWORD_A}. Confirm you stored it.' --output-format json" \
  2>/tmp/xuy8-a-plant.err)
A_PLANT_RC=$?
A_SESSION_ID=$(echo "$A_PLANT_OUT" | jq -r '.session_id // empty' 2>/dev/null)
if [[ "$A_PLANT_RC" -eq 0 && -n "$A_SESSION_ID" ]]; then
  pass "A1: planted a real session in scenario A (session_id=${A_SESSION_ID})"
else
  fail "A1: planting session A failed" "rc=${A_PLANT_RC} out=${A_PLANT_OUT} err=$(cat /tmp/xuy8-a-plant.err)"
fi

# Authoritative, non-LLM-mediated check: the HOST-side transcript file
# itself contains the real codeword, immediately after planting.
if grep -rlF "$CODEWORD_A" "${SCRATCH_A}/claude-dir/projects" >/dev/null 2>&1; then
  pass "A2: host-side transcript under the mounted claude-home contains the real planted codeword"
else
  fail "A2: no host-side transcript contains the codeword after planting" "$(find "${SCRATCH_A}/claude-dir/projects" -type f 2>&1)"
fi

# Cold-recreate over the SAME persistent mount (r8jl cheap-recreate pattern).
msb remove -f "$SBX_A" >/dev/null 2>&1 || true
A_RESUME_OUT=$(msb run --name "$SBX_A" --replace --timeout 90s "${NET_RULES[@]}" \
  -v "${SCRATCH_A}/claude-dir:/home/agent/.claude" \
  --mount-file "${SCRATCH_A}/claude.json:/home/agent/.claude.json" \
  --mount-file "${WRAPPER_SRC}:/home/agent/.rc-context/claude-wrapper.sh:ro" \
  -w /home/agent "$IMAGE" -- sh -c \
  "bash /home/agent/.rc-context/claude-wrapper.sh --resume ${A_SESSION_ID} -p 'What codeword did I ask you to remember? Reply with ONLY the codeword.' --output-format json" \
  2>/tmp/xuy8-a-resume.err)
A_RESUME_RC=$?
A_RESUME_RESULT=$(echo "$A_RESUME_OUT" | jq -r '.result // empty' 2>/dev/null)

# (1) The real planted session content reads back correctly -- the
# authoritative check: host-side transcript survives the recreate intact.
if grep -rlF "$CODEWORD_A" "${SCRATCH_A}/claude-dir/projects" >/dev/null 2>&1; then
  pass "A3 (acceptance 1): host-side session content is RECOVERED after cold-recreate -- the real planted codeword is still readable from the mounted claude-home"
else
  fail "A3 (acceptance 1): host-side session content did NOT survive the recreate" "$(find "${SCRATCH_A}/claude-dir/projects" -type f 2>&1)"
fi
# (bonus) functional corroboration: claude --resume actually recalls it.
if [[ "$A_RESUME_RC" -eq 0 && "$A_RESUME_RESULT" == *"$CODEWORD_A"* ]]; then
  pass "A4 (functional corroboration): claude --resume in the recreated cage recalled the real codeword: '${A_RESUME_RESULT}'"
else
  fail "A4: claude --resume did not recall the codeword" "rc=${A_RESUME_RC} result='${A_RESUME_RESULT}' err=$(cat /tmp/xuy8-a-resume.err)"
fi

# ===========================================================================
# SCENARIO B -- negative control: fix absent (projects/sessions NOT
# pre-created before first mount).
# ===========================================================================
echo ""
echo "=== SCENARIO B (fix ABSENT -- negative control): same sequence, no pre-create ==="
SCRATCH_B=$(mktemp -d)
_build_scratch_claude_home "$SCRATCH_B"
# Deliberately do NOT call _seed_claude_home_dirs -- this is the exact
# pre-rip-cage-xuy8 state: claude-dir/ exists (mount source must exist to
# mount at all) but projects/ and sessions/ inside it do not.
if [[ ! -d "${SCRATCH_B}/claude-dir/projects" && ! -d "${SCRATCH_B}/claude-dir/sessions" ]]; then
  pass "B0: claude-home root has NO projects/sessions dirs before first mount (fix genuinely absent)"
else
  fail "B0: scratch home unexpectedly has projects/sessions already" "$(ls -la "${SCRATCH_B}/claude-dir")"
fi

B_PLANT_OUT=$(msb run --name "$SBX_B" --replace --timeout 90s "${NET_RULES[@]}" \
  -v "${SCRATCH_B}/claude-dir:/home/agent/.claude" \
  --mount-file "${SCRATCH_B}/claude.json:/home/agent/.claude.json" \
  --mount-file "${WRAPPER_SRC}:/home/agent/.rc-context/claude-wrapper.sh:ro" \
  -w /home/agent "$IMAGE" -- sh -c \
  "bash /home/agent/.rc-context/claude-wrapper.sh -p 'Remember this codeword: ${CODEWORD_B}. Confirm you stored it.' --output-format json" \
  2>/tmp/xuy8-b-plant.err)
B_PLANT_RC=$?
B_SESSION_ID=$(echo "$B_PLANT_OUT" | jq -r '.session_id // empty' 2>/dev/null)
if [[ "$B_PLANT_RC" -eq 0 && -n "$B_SESSION_ID" ]]; then
  pass "B1: planted a real session in scenario B (session_id=${B_SESSION_ID})"
else
  fail "B1: planting session B failed" "rc=${B_PLANT_RC} out=${B_PLANT_OUT} err=$(cat /tmp/xuy8-b-plant.err)"
fi

# The footgun firing: the host-mounted claude-home did NOT receive the
# transcript (it landed in the guest's ephemeral per-session dir instead,
# which is not host-mounted at all).
if ! grep -rlF "$CODEWORD_B" "${SCRATCH_B}/claude-dir" >/dev/null 2>&1; then
  pass "B2: host-side claude-home mount received NO transcript (footgun reproduced -- session state went to the ephemeral guest dir, not the host mount)"
else
  fail "B2: host-side claude-home unexpectedly received the transcript (footgun did NOT reproduce)" "$(grep -rl "$CODEWORD_B" "${SCRATCH_B}/claude-dir" 2>&1)"
fi

# Cold-recreate over the SAME persistent mount -- the ephemeral guest-overlay
# session data is discarded (r8jl: cold --replace does not preserve overlay).
msb remove -f "$SBX_B" >/dev/null 2>&1 || true
B_RESUME_OUT=$(msb run --name "$SBX_B" --replace --timeout 90s "${NET_RULES[@]}" \
  -v "${SCRATCH_B}/claude-dir:/home/agent/.claude" \
  --mount-file "${SCRATCH_B}/claude.json:/home/agent/.claude.json" \
  --mount-file "${WRAPPER_SRC}:/home/agent/.rc-context/claude-wrapper.sh:ro" \
  -w /home/agent "$IMAGE" -- sh -c \
  "bash /home/agent/.rc-context/claude-wrapper.sh --resume ${B_SESSION_ID} -p 'What codeword did I ask you to remember? Reply with ONLY the codeword, or say NO_KNOWLEDGE if you do not know.' --output-format json" \
  2>/tmp/xuy8-b-resume.err)
B_RESUME_RC=$?
B_RESUME_RESULT=$(echo "$B_RESUME_OUT" | jq -r '.result // empty' 2>/dev/null)

# (2) Negative control: a cage lacking the fix fails to recover the same
# session -- loud/observable, not a silent pass. Assert the recovered
# codeword is genuinely absent (whichever failure shape claude surfaces:
# explicit "no such session" error, or an answer that does not know it).
if [[ "$B_RESUME_RESULT" != *"$CODEWORD_B"* ]]; then
  pass "B3 (acceptance 2): negative control -- cage LACKING the fix fails to recover the codeword. claude --resume output: rc=${B_RESUME_RC} result='${B_RESUME_RESULT}' stderr='$(cat /tmp/xuy8-b-resume.err)'"
else
  fail "B3 (acceptance 2): negative control did NOT fail -- codeword was unexpectedly recovered without the fix" "result='${B_RESUME_RESULT}'"
fi

# ===========================================================================
# Safety: real host ~/.claude was never touched.
# ===========================================================================
echo ""
REAL_CLAUDE_MTIME_AFTER=$(stat -f "%m" "${HOME}/.claude/.credentials.json" 2>/dev/null || stat -c "%Y" "${HOME}/.claude/.credentials.json" 2>/dev/null)
if [[ "$REAL_CLAUDE_MTIME_BEFORE" == "$REAL_CLAUDE_MTIME_AFTER" ]]; then
  pass "SAFETY: real ~/.claude/.credentials.json mtime unchanged (never touched)"
else
  fail "SAFETY: real ~/.claude/.credentials.json mtime CHANGED" "before=${REAL_CLAUDE_MTIME_BEFORE} after=${REAL_CLAUDE_MTIME_AFTER}"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-claude-home-resume.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-claude-home-resume.sh: all ${TOTAL} tests passed ==="
